package bridge

import (
	"archive/zip"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

// A chats backup is a zip of chats.json, the history the host builds,
// and media/ entries, sealed under a password when one is given. Media
// is decrypted into it, and out of it into the vault, as it streams.

const (
	chatsKind  = "tincan-chats"
	chatsIndex = "chats.json"
	spillGlob  = ".spill-*"
)

var errNotChats = errors.New("not a Tincan chats file")

// ChatsMedia is one sealed media file and its name in the backup.
type ChatsMedia struct {
	Path string `json:"path"`
	Name string `json:"name"`
}

// ExportChats writes index and media to dst, atomically.
func (v *Vault) ExportChats(dst string, password, index []byte, media []ChatsMedia) error {
	fill := func(w io.Writer) error {
		zw := zip.NewWriter(w)
		for _, m := range media {
			if err := v.zipMedia(zw, m); err != nil {
				return err
			}
		}
		iw, err := zw.Create(chatsIndex)
		if err == nil {
			_, err = iw.Write(index)
		}
		if err != nil {
			return err
		}
		return zw.Close()
	}
	if len(password) == 0 {
		return writeFileAtomic(dst, 0600, fill)
	}
	return sealStream(dst, password, fill)
}

func (v *Vault) zipMedia(zw *zip.Writer, m ChatsMedia) error {
	in, err := os.Open(m.Path)
	if err != nil {
		return err
	}
	defer in.Close()
	// Media is compressed already.
	w, err := zw.CreateHeader(&zip.FileHeader{Name: m.Name, Method: zip.Store, Modified: time.Now()})
	if err != nil {
		return err
	}
	_, err = io.Copy(w, v.ChunkReader(in))
	return err
}

// ImportChats seals each media entry of the backup at src into
// mediaDir, returning the index and where each entry landed. A sealed
// backup is read back through a spill under a throwaway key, so its
// plaintext never reaches disk.
func (v *Vault) ImportChats(src string, password []byte, mediaDir string) (index []byte, media map[string]string, err error) {
	if err := v.withKey(func([]byte) error { return nil }); err != nil {
		return nil, nil, err
	}
	in, err := os.Open(src)
	if err != nil {
		return nil, nil, err
	}
	defer in.Close()
	st, err := in.Stat()
	if err != nil {
		return nil, nil, err
	}
	var ra io.ReaderAt = in
	size := st.Size()
	var magic [len(backupMagic)]byte
	if _, err := io.ReadFull(in, magic[:]); err == nil && string(magic[:]) == backupMagic {
		r, key, err := openStream(in, password)
		if err != nil {
			return nil, nil, err
		}
		defer clear(key)
		v.sweepSpills()
		sp, err := newSpill(v.dir, r)
		if err != nil {
			return nil, nil, err
		}
		defer sp.Close()
		ra, size = sp, sp.size
	}
	zr, err := zip.NewReader(ra, size)
	if err != nil {
		return nil, nil, errNotChats
	}
	if index, err = readIndex(zr); err != nil {
		return nil, nil, err
	}
	media = map[string]string{}
	defer func() {
		if err != nil {
			for _, p := range media {
				os.Remove(p)
			}
		}
	}()
	for _, f := range zr.File {
		if !strings.HasPrefix(f.Name, "media/") || f.FileInfo().IsDir() {
			continue
		}
		p, err := v.unzipMedia(f, mediaDir)
		if err != nil {
			return nil, media, err
		}
		media[f.Name] = p
	}
	return index, media, nil
}

func readIndex(zr *zip.Reader) ([]byte, error) {
	for _, f := range zr.File {
		if f.Name != chatsIndex {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return nil, err
		}
		defer rc.Close()
		b, err := io.ReadAll(io.LimitReader(rc, 1<<30))
		if err != nil {
			return nil, err
		}
		var head struct {
			Kind string `json:"kind"`
		}
		if json.Unmarshal(b, &head) != nil || head.Kind != chatsKind {
			return nil, errNotChats
		}
		return b, nil
	}
	return nil, errNotChats
}

func (v *Vault) unzipMedia(f *zip.File, mediaDir string) (string, error) {
	rc, err := f.Open()
	if err != nil {
		return "", err
	}
	defer rc.Close()
	out, final, err := createUnique(mediaDir, sanitizeName(path.Base(f.Name)))
	if err != nil {
		return "", err
	}
	cw := v.ChunkWriter(out)
	if _, err = io.Copy(cw, rc); err == nil {
		err = cw.Close()
	}
	if err != nil {
		out.Close()
		os.Remove(final + ".part")
		return "", err
	}
	return final, commitPart(out, final)
}

// sweepSpills drops what a killed import left; unreadable without its key.
func (v *Vault) sweepSpills() {
	old, _ := filepath.Glob(filepath.Join(v.dir, spillGlob))
	for _, p := range old {
		os.Remove(p)
	}
}

// spill holds a stream in a temp file sealed chunk by chunk under a key
// that only lives in memory, and reads it back at random.
type spill struct {
	f    *os.File
	key  []byte
	size int64
	at   int64 // which chunk buf holds
	buf  []byte
}

const spillRecord = chunkSize + chacha20poly1305.NonceSizeX + chacha20poly1305.Overhead

func spillAAD(i int64) []byte { return binary.BigEndian.AppendUint64(nil, uint64(i)) }

func newSpill(dir string, r io.Reader) (*spill, error) {
	f, err := os.CreateTemp(dir, spillGlob)
	if err != nil {
		return nil, err
	}
	s := &spill{f: f, key: make([]byte, 32), at: -1}
	if _, err := rand.Read(s.key); err != nil {
		s.Close()
		return nil, err
	}
	buf := make([]byte, chunkSize)
	defer clear(buf)
	var blob []byte
	for i := int64(0); ; i++ {
		n, rerr := io.ReadFull(r, buf)
		if n > 0 {
			blob, err = sealAppend(blob[:0], s.key, buf[:n], spillAAD(i))
			if err == nil {
				_, err = f.Write(blob)
			}
			if err != nil {
				s.Close()
				return nil, err
			}
			s.size += int64(n)
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			return s, nil
		}
		if rerr != nil {
			s.Close()
			return nil, rerr
		}
	}
}

func (s *spill) ReadAt(p []byte, off int64) (int, error) {
	n := 0
	for len(p) > 0 {
		if off >= s.size {
			return n, io.EOF
		}
		i := off / chunkSize
		if i != s.at {
			if err := s.load(i); err != nil {
				return n, err
			}
		}
		k := copy(p, s.buf[off-i*chunkSize:])
		p, off, n = p[k:], off+int64(k), n+k
	}
	return n, nil
}

func (s *spill) load(i int64) error {
	blob := make([]byte, spillRecord)
	n, err := s.f.ReadAt(blob, i*spillRecord)
	if err != nil && !(err == io.EOF && n > 0) {
		return err
	}
	plain, err := open(s.key, blob[:n], spillAAD(i))
	if err != nil {
		return err
	}
	clear(s.buf)
	s.buf, s.at = plain, i
	return nil
}

func (s *spill) Close() error {
	clear(s.key)
	clear(s.buf)
	err := s.f.Close()
	os.Remove(s.f.Name())
	return err
}
