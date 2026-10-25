package bridge

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sync"

	"github.com/tailscale/tailcat"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
	"tailscale.com/types/key"
)

// Everything the app keeps — the private key above all, but also the
// message history, the roster and received media — is encrypted on disk
// with one data key. That key is itself wrapped by a secret the host
// supplies: a password the user types, or a random one the platform
// keystore holds behind biometrics, or with no prompt at all for "none".
//
// Filenames are not encrypted. The names of received files stay
// readable on disk even though their contents do not.

const vaultFile = "vault.json"

// Version 2 binds state files and media chunks to where they belong.
const vaultVersion = 2

type vaultHeader struct {
	Version int    `json:"v"`
	KDF     string `json:"kdf"` // argon2id for passwords, hkdf for keystore secrets
	Salt    []byte `json:"salt"`
	Wrapped []byte `json:"wrapped"`
	Mode    string `json:"mode"` // password | device | none, for the UI
}

// Vault seals and opens files with the data key.
type Vault struct {
	mu     sync.RWMutex
	key    []byte // nil once locked
	dir    string // the stateDir holding vault.json and the account files
	legacy bool   // a v1 vault, which may still hold unbound files
}

var errLocked = errors.New("locked")

// Argon2id parameters. 64 MiB is heavy enough to matter on a stolen
// phone and still unlocks in about a second on a slow one.
const (
	argonTime    = 3
	argonMemory  = 64 * 1024
	argonThreads = 4
)

func deriveKey(kdf string, secret, salt []byte) ([]byte, error) {
	switch kdf {
	case "argon2id":
		return argon2.IDKey(secret, salt, argonTime, argonMemory, argonThreads, 32), nil
	case "hkdf":
		// The secret is already 256 random bits; stretching it buys
		// nothing but unlock latency.
		key := make([]byte, 32)
		if _, err := io.ReadFull(hkdf.New(sha256.New, secret, salt, []byte("tincan vault")), key); err != nil {
			return nil, err
		}
		return key, nil
	}
	return nil, fmt.Errorf("unknown key derivation %q", kdf)
}

func seal(key, plaintext, aad []byte) ([]byte, error) {
	return sealAppend(nil, key, plaintext, aad)
}

// sealAppend appends nonce||ciphertext to dst.
func sealAppend(dst, key, plaintext, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	n := len(dst)
	out := slices.Grow(dst, aead.NonceSize()+len(plaintext)+aead.Overhead())[:n+aead.NonceSize()]
	nonce := out[n:]
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(out, nonce, plaintext, aad), nil
}

func open(key, blob, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	if len(blob) < aead.NonceSize() {
		return nil, errors.New("ciphertext truncated")
	}
	nonce, ct := blob[:aead.NonceSize()], blob[aead.NonceSize():]
	return aead.Open(nil, nonce, ct, aad)
}

func headerPath(stateDir string) string { return filepath.Join(stateDir, vaultFile) }

func readHeader(stateDir string) (*vaultHeader, error) {
	j, err := os.ReadFile(headerPath(stateDir))
	if err != nil {
		return nil, err
	}
	h := new(vaultHeader)
	if err := json.Unmarshal(j, h); err != nil {
		return nil, fmt.Errorf("corrupt %s: %w", vaultFile, err)
	}
	return h, nil
}

// writeHeader wraps dek under secret with a fresh salt.
func writeHeader(stateDir, secret, mode string, dek []byte, version int) error {
	if secret == "" {
		return errors.New("a vault needs a secret")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	kdf := "argon2id"
	if mode == "device" || mode == "none" {
		kdf = "hkdf"
	}
	pw := []byte(secret)
	kek, err := deriveKey(kdf, pw, salt)
	clear(pw)
	if err != nil {
		return err
	}
	wrapped, err := seal(kek, dek, nil)
	clear(kek)
	if err != nil {
		return err
	}
	j, err := json.MarshalIndent(
		vaultHeader{Version: version, KDF: kdf, Salt: salt, Wrapped: wrapped, Mode: mode}, "", "\t")
	if err != nil {
		return err
	}
	return writeBytesAtomic(headerPath(stateDir), 0600, j)
}

// stageFile fills a temp file beside path for a later rename over it.
func stageFile(path string, perm os.FileMode, fill func(w io.Writer) error) (string, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp*")
	if err != nil {
		return "", err
	}
	tmp := f.Name()
	err = fill(f)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp, perm)
	}
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	return tmp, nil
}

// writeFileAtomic fills a temp file beside path and renames it over
// path, so a process killed mid-write (Android does this freely)
// leaves the old file whole rather than a truncated one.
func writeFileAtomic(path string, perm os.FileMode, fill func(w io.Writer) error) error {
	tmp, err := stageFile(path, perm, fill)
	if err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func writeBytesAtomic(path string, perm os.FileMode, b []byte) error {
	return writeFileAtomic(path, perm, func(w io.Writer) error {
		_, err := w.Write(b)
		return err
	})
}

// createUnique opens dir/name.part exclusively, stepping to "name (2)"
// and so on when taken, and returns the path to rename it to.
func createUnique(dir, name string) (*os.File, string, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, "", err
	}
	return openUnique(dir, storedName(name), ".part")
}

// commitPart closes a file from createUnique and moves it into place.
func commitPart(f *os.File, final string) error {
	err := f.Close()
	if err == nil {
		err = os.Rename(final+".part", final)
	}
	if err != nil {
		os.Remove(final + ".part")
	}
	return err
}

// VaultExists reports whether stateDir already holds a vault, and how
// it is protected. A header that is there but unreadable is an error,
// not an absence: treating it as absent would let setup overwrite it.
func VaultExists(stateDir string) (exists bool, mode string, err error) {
	h, err := readHeader(stateDir)
	if errors.Is(err, os.ErrNotExist) {
		return false, "", nil
	}
	if err != nil {
		return false, "", err
	}
	return true, h.Mode, nil
}

// CreateVault generates a data key and wraps it with secret. mode is
// "password", "device" or "none" and only steers the unlock UI.
func CreateVault(stateDir, secret, mode string) error {
	exists, _, err := VaultExists(stateDir)
	if err != nil {
		return err
	}
	if exists {
		return errors.New("a vault already exists here")
	}
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return err
	}
	dek := make([]byte, 32)
	defer clear(dek)
	if _, err := rand.Read(dek); err != nil {
		return err
	}
	return writeHeader(stateDir, secret, mode, dek, vaultVersion)
}

// OpenVault unwraps the data key. A wrong secret fails here.
func OpenVault(stateDir, secret string) (*Vault, error) {
	h, err := readHeader(stateDir)
	if err != nil {
		return nil, err
	}
	pw := []byte(secret)
	kek, err := deriveKey(h.KDF, pw, h.Salt)
	clear(pw)
	if err != nil {
		return nil, err
	}
	dek, err := open(kek, h.Wrapped, nil)
	clear(kek)
	if err != nil {
		return nil, errors.New("wrong password")
	}
	if h.Version > vaultVersion {
		clear(dek)
		return nil, fmt.Errorf("this vault is from a newer version of the app (format %d)", h.Version)
	}
	if err := rollbackImport(stateDir); err != nil {
		clear(dek)
		return nil, fmt.Errorf("undoing an interrupted account import: %w", err)
	}
	return &Vault{key: dek, dir: stateDir, legacy: h.Version < 2}, nil
}

// Lock zeroes the data key. Every later use of v fails; unlocking
// again means opening a new Vault.
func (v *Vault) Lock() {
	v.mu.Lock()
	defer v.mu.Unlock()
	clear(v.key)
	v.key = nil
}

func (v *Vault) withKey(f func(key []byte) error) error {
	v.mu.RLock()
	defer v.mu.RUnlock()
	if v.key == nil {
		return errLocked
	}
	return f(v.key)
}

// ChangeSecret rewraps the same data key under a new secret, so
// switching between a password and biometrics leaves the data alone.
func (v *Vault) ChangeSecret(secret, mode string) error {
	version := vaultVersion
	if v.legacy {
		version = 1
	}
	return v.withKey(func(key []byte) error {
		return writeHeader(v.dir, secret, mode, key, version)
	})
}

// Upgrade reseals the unbound files a version 1 vault holds, under its
// state dir and mediaDirs, then marks it version 2 so unbound files stop
// opening. Run it before anything else reads or writes those files.
func (v *Vault) Upgrade(mediaDirs ...string) error {
	if !v.legacy {
		return nil
	}
	for _, dir := range append([]string{v.dir}, mediaDirs...) {
		err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			switch {
			case err != nil:
				if path == dir && errors.Is(err, fs.ErrNotExist) {
					return nil
				}
				return err
			case d.IsDir():
				if d.Name() == partialDir {
					return filepath.SkipDir // resumes start over on foreign parts anyway
				}
				return nil
			case !d.Type().IsRegular() || path == headerPath(v.dir) || path == filepath.Join(v.dir, importJournal):
				return nil
			}
			if err := v.upgradeFile(path); err != nil {
				return fmt.Errorf("upgrading %s: %w", path, err)
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	h, err := readHeader(v.dir)
	if err != nil {
		return err
	}
	h.Version = vaultVersion
	j, err := json.MarshalIndent(h, "", "\t")
	if err != nil {
		return err
	}
	if err := writeBytesAtomic(headerPath(v.dir), 0600, j); err != nil {
		return err
	}
	v.mu.Lock()
	v.legacy = false
	v.mu.Unlock()
	return nil
}

const maxLegacyState = 256 << 20

// upgradeFile reseals path if it opens as an unbound state file or
// unbound media, and leaves anything else alone.
func (v *Vault) upgradeFile(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	var magic [len(stateMagic)]byte
	if _, err := io.ReadFull(f, magic[:]); err == nil && (string(magic[:]) == stateMagic || string(magic[:]) == mediaMagic) {
		return nil
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	br := bufio.NewReader(f)
	if blob, err := readLenPrefixed(br, maxSealedChunk); err == nil {
		err = v.withKey(func(key []byte) error {
			plain, err := open(key, blob, nil)
			clear(plain)
			return err
		})
		if errors.Is(err, errLocked) {
			return err
		}
		if err == nil {
			if _, err := f.Seek(0, io.SeekStart); err != nil {
				return err
			}
			return v.createMedia(path, fi.Mode().Perm(), func(w io.Writer) error {
				_, err := io.Copy(w, &legacyChunkReader{v: v, r: bufio.NewReader(f)})
				return err
			})
		}
	}
	if fi.Size() > maxLegacyState {
		return nil
	}
	blob, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var plain []byte
	err = v.withKey(func(key []byte) (err error) {
		plain, err = open(key, blob, nil)
		return err
	})
	if errors.Is(err, errLocked) {
		return err
	}
	if err != nil {
		return nil // not ours
	}
	defer clear(plain)
	return v.WriteFile(path, plain, fi.Mode().Perm())
}

// bind is the associated data tying a sealed file to its path relative
// to the state dir, which survives the app's data dir moving.
func (v *Vault) bind(kind, path string) []byte {
	rel := path
	if abs, err := filepath.Abs(path); err == nil {
		rel = abs
	}
	if base, err := filepath.Abs(v.dir); err == nil {
		if r, err := filepath.Rel(base, rel); err == nil {
			rel = r
		}
	}
	return []byte("tincan " + kind + "\x00" + filepath.ToSlash(rel) + "\x00")
}

const stateMagic = "TCS\x02"

// sealState is the on-disk form of a state file at path.
func (v *Vault) sealState(path string, data []byte) (blob []byte, err error) {
	err = v.withKey(func(key []byte) (err error) {
		blob, err = sealAppend([]byte(stateMagic), key, data, v.bind("state", path))
		return err
	})
	return blob, err
}

// WriteFile seals data bound to path, always in the current format,
// so an old file is upgraded the next time it is saved.
func (v *Vault) WriteFile(path string, data []byte, perm os.FileMode) error {
	blob, err := v.sealState(path, data)
	if err != nil {
		return err
	}
	return writeBytesAtomic(path, perm, blob)
}

func (v *Vault) ReadFile(path string) ([]byte, error) {
	blob, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var plain []byte
	err = v.withKey(func(key []byte) error {
		err := errors.New("not a sealed file")
		if b, ok := bytes.CutPrefix(blob, []byte(stateMagic)); ok {
			if plain, err = open(key, b, v.bind("state", path)); err == nil {
				return nil
			}
		}
		if v.legacy {
			var lerr error
			if plain, lerr = open(key, blob, nil); lerr == nil {
				return nil
			}
		}
		return err
	})
	return plain, err
}

// RemoveFile deletes a state file; one already gone is fine.
func (v *Vault) RemoveFile(path string) error {
	return v.withKey(func([]byte) error {
		if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		return nil
	})
}

// ListDir names the files in dir; a missing dir has none.
func (v *Vault) ListDir(dir string) ([]string, error) {
	names := []string{}
	err := v.withKey(func([]byte) error {
		entries, err := os.ReadDir(dir)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		for _, e := range entries {
			if e.Type().IsRegular() {
				names = append(names, e.Name())
			}
		}
		return err
	})
	if err != nil {
		return nil, err
	}
	return names, nil
}

// RenameFile moves a state file, resealing it for its new path since
// seals are bound to where they live. One that won't open is moved as
// is: it was unreadable already.
func (v *Vault) RenameFile(src, dst string) error {
	plain, err := v.ReadFile(src)
	if errors.Is(err, errLocked) || errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err != nil {
		return os.Rename(src, dst)
	}
	defer clear(plain)
	if err := v.WriteFile(dst, plain, 0600); err != nil {
		return err
	}
	return os.Remove(src)
}

func (v *Vault) String() string {
	v.mu.RLock()
	defer v.mu.RUnlock()
	if v.key == nil {
		return "Vault(locked)"
	}
	return "Vault(" + v.dir + ")"
}

// Media is a header holding a random id, then length-prefixed sealed
// chunks bound to that id, their index and a last flag. The id, not the
// path, since transfers are renamed when they finish.

const (
	maxSealedChunk = 1 << 20
	mediaMagic     = "TCM\x02"
	mediaIDSize    = 16
)

var errTruncated = errors.New("sealed file is truncated")

type keyFunc func(f func(key []byte) error) error

func staticKey(key []byte) keyFunc {
	return func(f func(key []byte) error) error { return f(key) }
}

func chunkAAD(bind []byte, i uint64, last bool) []byte {
	aad := binary.BigEndian.AppendUint64(slices.Clip(bind), i)
	if last {
		return append(aad, 1)
	}
	return append(aad, 0)
}

func mediaBind(id []byte) []byte { return append([]byte("tincan media\x00"), id...) }

// ChunkWriter seals a stream in chunkSize chunks. Close seals what is
// left and the last-chunk marker, without which the file reads as
// truncated; it leaves the underlying writer open.
type ChunkWriter struct {
	key    keyFunc
	bind   []byte
	w      io.Writer
	header []byte // still to write before the first chunk
	buf    []byte
	n      uint64
	err    error
	closed bool
}

func newChunkWriter(key keyFunc, bind []byte, w io.Writer, header []byte) *ChunkWriter {
	return &ChunkWriter{key: key, bind: bind, w: w, header: header, buf: make([]byte, 0, chunkSize)}
}

// ChunkWriter seals media into w under a fresh file id.
func (v *Vault) ChunkWriter(w io.Writer) *ChunkWriter {
	id := make([]byte, mediaIDSize)
	rand.Read(id)
	return newChunkWriter(v.withKey, mediaBind(id), w, append([]byte(mediaMagic), id...))
}

func (c *ChunkWriter) Write(p []byte) (int, error) {
	if c.closed {
		return 0, errors.New("write after close")
	}
	n := 0
	for len(p) > 0 && c.err == nil {
		k := copy(c.buf[len(c.buf):chunkSize], p)
		c.buf = c.buf[:len(c.buf)+k]
		p, n = p[k:], n+k
		if len(c.buf) == chunkSize {
			c.err = c.emit(false)
		}
	}
	return n, c.err
}

// Close seals the buffered tail and the last-chunk marker.
func (c *ChunkWriter) Close() error {
	if c.closed || c.err != nil {
		return c.err
	}
	c.closed = true
	if len(c.buf) > 0 {
		c.err = c.emit(false)
	}
	if c.err == nil {
		c.err = c.emit(true)
	}
	return c.err
}

func (c *ChunkWriter) emit(last bool) error {
	var blob []byte
	err := c.key(func(key []byte) (err error) {
		blob, err = seal(key, c.buf, chunkAAD(c.bind, c.n, last))
		return err
	})
	clear(c.buf)
	c.buf = c.buf[:0]
	if err != nil {
		return err
	}
	if len(c.header) > 0 {
		if _, err := c.w.Write(c.header); err != nil {
			return err
		}
		c.header = nil
	}
	c.n++
	return writeLenPrefixed(c.w, blob)
}

type chunkReader struct {
	key      keyFunc
	bind     []byte
	r        io.Reader
	buf      []byte
	n        uint64
	last     bool
	err      error
	firstErr error // reported when chunk 0 fails, e.g. a wrong password
}

func (c *chunkReader) Read(p []byte) (int, error) {
	for len(c.buf) == 0 {
		if c.err != nil {
			return 0, c.err
		}
		c.err = c.next()
	}
	n := copy(p, c.buf)
	c.buf = c.buf[n:]
	return n, nil
}

func (c *chunkReader) next() error {
	if c.last {
		var b [1]byte
		n, err := io.ReadFull(c.r, b[:])
		if n > 0 {
			return errors.New("data after the last sealed chunk")
		}
		return err
	}
	blob, err := readLenPrefixed(c.r, maxSealedChunk)
	if err == io.EOF || err == io.ErrUnexpectedEOF {
		return errTruncated
	}
	if err != nil {
		return err
	}
	return c.key(func(key []byte) error {
		plain, err := open(key, blob, chunkAAD(c.bind, c.n, false))
		if err != nil {
			plain, err = open(key, blob, chunkAAD(c.bind, c.n, true))
			c.last = err == nil
		}
		if err != nil && c.n == 0 && c.firstErr != nil {
			return c.firstErr
		}
		if err != nil {
			return err
		}
		c.buf = plain
		c.n++
		return nil
	})
}

type legacyChunkReader struct {
	v   *Vault
	r   io.Reader
	buf []byte
}

func (c *legacyChunkReader) Read(p []byte) (int, error) {
	for len(c.buf) == 0 {
		blob, err := readLenPrefixed(c.r, maxSealedChunk)
		if err != nil {
			return 0, err // a clean io.EOF only between chunks
		}
		err = c.v.withKey(func(key []byte) (err error) {
			c.buf, err = open(key, blob, nil)
			return err
		})
		if err != nil {
			return 0, err
		}
	}
	n := copy(p, c.buf)
	c.buf = c.buf[n:]
	return n, nil
}

type mediaReader struct {
	v     *Vault
	r     io.Reader
	inner io.Reader
	err   error
}

// ChunkReader opens what ChunkWriter sealed, as a plain byte stream.
func (v *Vault) ChunkReader(r io.Reader) io.Reader { return &mediaReader{v: v, r: r} }

func (m *mediaReader) Read(p []byte) (int, error) {
	if m.inner == nil && m.err == nil {
		var magic [len(mediaMagic)]byte
		n, err := io.ReadFull(m.r, magic[:])
		switch {
		case err == nil && string(magic[:]) == mediaMagic:
			id := make([]byte, mediaIDSize)
			if _, err := io.ReadFull(m.r, id); err != nil {
				m.err = errTruncated
				break
			}
			m.inner = &chunkReader{key: m.v.withKey, bind: mediaBind(id), r: m.r}
		case err != nil && err != io.EOF && err != io.ErrUnexpectedEOF:
			m.err = err
		case m.v.legacy:
			m.inner = &legacyChunkReader{v: m.v, r: io.MultiReader(bytes.NewReader(magic[:n]), m.r)}
		default:
			m.err = errors.New("not a sealed file")
		}
	}
	if m.err != nil {
		return 0, m.err
	}
	return m.inner.Read(p)
}

func (v *Vault) stageMedia(path string, perm os.FileMode, fill func(w io.Writer) error) (string, error) {
	return stageFile(path, perm, sealedFill(v, fill))
}

func sealedFill(v *Vault, fill func(w io.Writer) error) func(w io.Writer) error {
	return func(w io.Writer) error {
		cw := v.ChunkWriter(w)
		if err := fill(cw); err != nil {
			return err
		}
		return cw.Close()
	}
}

// createMedia writes path through a ChunkWriter filled by fill.
func (v *Vault) createMedia(path string, perm os.FileMode, fill func(w io.Writer) error) error {
	return writeFileAtomic(path, perm, sealedFill(v, fill))
}

func writeAll(data []byte) func(w io.Writer) error {
	return func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	}
}

// WriteMedia seals data in the chunked format, so images and files
// share one on-disk format and one decrypt path.
func (v *Vault) WriteMedia(path string, data []byte, perm os.FileMode) error {
	return v.createMedia(path, perm, writeAll(data))
}

// MediaSize is the plaintext size of a chunked file, read off the
// chunk headers without decrypting.
func (v *Vault) MediaSize(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return 0, err
	}
	var magic [len(mediaMagic)]byte
	headed := false
	switch _, err := io.ReadFull(f, magic[:]); {
	case err == nil && string(magic[:]) == mediaMagic:
		if fi.Size() < int64(len(magic)+mediaIDSize) {
			return 0, errTruncated
		}
		headed = true
	case err != nil && err != io.EOF && err != io.ErrUnexpectedEOF:
		return 0, err
	case !v.legacy:
		return 0, errors.New("not a sealed file")
	}
	off := int64(0)
	if headed {
		off = int64(len(magic) + mediaIDSize)
	}
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return 0, err
	}
	overhead := int64(chacha20poly1305.NonceSizeX + chacha20poly1305.Overhead)
	var size int64
	for {
		n, err := readLen(f, maxSealedChunk)
		if err == io.EOF {
			if headed && off == int64(len(magic)+mediaIDSize) {
				return 0, errTruncated // a sealed stream always ends with a last chunk
			}
			return size, nil
		}
		if err == io.ErrUnexpectedEOF {
			return 0, errTruncated
		}
		if err != nil {
			return 0, err
		}
		if int64(n) < overhead {
			return 0, fmt.Errorf("bad chunk length %d", n)
		}
		if off += 4 + int64(n); off > fi.Size() {
			return 0, errTruncated
		}
		if _, err := f.Seek(off, io.SeekStart); err != nil {
			return 0, err
		}
		size += int64(n) - overhead
	}
}

// ReadMedia reads a chunked file into memory.
func (v *Vault) ReadMedia(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(v.ChunkReader(f))
}

// DecryptFile writes the plaintext of a chunked file to dst.
func (v *Vault) DecryptFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	return writeFileAtomic(dst, 0600, func(w io.Writer) error {
		_, err := io.Copy(w, v.ChunkReader(in))
		return err
	})
}

// ResumePart carries on sealing into f, a partial transfer opened
// read-write. It keeps the whole chunks f already holds, cuts any torn
// or foreign tail, and returns the plaintext bytes kept with a writer
// that appends after them. An empty or unreadable f starts over.
func (v *Vault) ResumePart(f *os.File) (*ChunkWriter, int64, error) {
	hdr := make([]byte, len(mediaMagic)+mediaIDSize)
	var cw *ChunkWriter
	var off, have int64
	if _, err := f.ReadAt(hdr, 0); err == nil && string(hdr[:len(mediaMagic)]) == mediaMagic {
		cw = newChunkWriter(v.withKey, mediaBind(hdr[len(mediaMagic):]), f, nil)
		var err error
		if off, have, err = v.resumeFast(f, cw); err == nil && off < 0 {
			off, have, err = v.resumeScan(f, cw)
		}
		if err != nil {
			return nil, 0, err
		}
	} else {
		cw = v.ChunkWriter(f)
	}
	err := f.Truncate(off)
	if err == nil {
		_, err = f.Seek(off, io.SeekStart)
	}
	if err != nil {
		return nil, 0, err
	}
	return cw, have, nil
}

// resumeFast relies on a part holding only full chunks, as ChunkWriter
// leaves it before Close, and opens just the last whole one. off < 0
// means the layout didn't hold.
func (v *Vault) resumeFast(f *os.File, cw *ChunkWriter) (off, have int64, err error) {
	fi, err := f.Stat()
	if err != nil {
		return 0, 0, err
	}
	start := int64(len(mediaMagic) + mediaIDSize)
	blobLen := int64(chacha20poly1305.NonceSizeX + chunkSize + chacha20poly1305.Overhead)
	rec := 4 + blobLen
	n := (fi.Size() - start) / rec
	if n <= 0 {
		return start, 0, nil
	}
	b := make([]byte, rec)
	if _, err := f.ReadAt(b, start+(n-1)*rec); err != nil {
		return 0, 0, err
	}
	if int64(binary.BigEndian.Uint32(b)) != blobLen {
		return -1, 0, nil
	}
	err = v.withKey(func(key []byte) error {
		plain, err := open(key, b[4:], chunkAAD(cw.bind, uint64(n-1), false))
		clear(plain)
		return err
	})
	if errors.Is(err, errLocked) {
		return 0, 0, err
	}
	if err != nil {
		return -1, 0, nil
	}
	cw.n = uint64(n)
	return start + n*rec, n * chunkSize, nil
}

// resumeScan opens chunk after chunk until one fails.
func (v *Vault) resumeScan(f *os.File, cw *ChunkWriter) (off, have int64, err error) {
	off = int64(len(mediaMagic) + mediaIDSize)
	if _, err := f.Seek(off, io.SeekStart); err != nil {
		return 0, 0, err
	}
	br := bufio.NewReader(f)
	for {
		blob, err := readLenPrefixed(br, maxSealedChunk)
		if err != nil {
			return off, have, nil
		}
		var plain []byte
		err = v.withKey(func(key []byte) (err error) {
			plain, err = open(key, blob, chunkAAD(cw.bind, cw.n, false))
			return err
		})
		if errors.Is(err, errLocked) {
			return 0, 0, err
		}
		if err != nil {
			return off, have, nil
		}
		clear(plain)
		off += 4 + int64(len(blob))
		have += int64(len(plain))
		cw.n++
	}
}

// Password-sealed files (account and chat backups) are a magic, an
// argon2id salt, then a sealed stream bound to that salt.

const backupMagic = "TCB\x01"

var (
	ErrPasswordRequired = errors.New("password required")
	errWrongPassword    = errors.New("wrong password")
)

func backupKey(password, salt []byte) []byte {
	return argon2.IDKey(password, salt, argonTime, argonMemory, argonThreads, 32)
}

func backupBind(salt []byte) []byte {
	return append([]byte("tincan backup\x00"), salt...)
}

// sealStream writes what fill produces to dst under password.
func sealStream(dst string, password []byte, fill func(w io.Writer) error) error {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return err
	}
	key := backupKey(password, salt)
	defer clear(key)
	return writeFileAtomic(dst, 0600, func(w io.Writer) error {
		if _, err := io.WriteString(w, backupMagic+string(salt)); err != nil {
			return err
		}
		cw := newChunkWriter(staticKey(key), backupBind(salt), w, nil)
		if err := fill(cw); err != nil {
			return err
		}
		return cw.Close()
	})
}

// openStream reads a password-sealed file from r, whose magic has
// already been consumed. The caller zeroes the returned key.
func openStream(r io.Reader, password []byte) (io.Reader, []byte, error) {
	if len(password) == 0 {
		return nil, nil, ErrPasswordRequired
	}
	salt := make([]byte, 16)
	if _, err := io.ReadFull(r, salt); err != nil {
		return nil, nil, errTruncated
	}
	key := backupKey(password, salt)
	return &chunkReader{key: staticKey(key), bind: backupBind(salt), r: r, firstErr: errWrongPassword}, key, nil
}

// SealFile encrypts src into dst under password, streaming.
func SealFile(src, dst string, password []byte) error {
	if len(password) == 0 {
		return ErrPasswordRequired
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	return sealStream(dst, password, func(w io.Writer) error {
		_, err := io.Copy(w, in)
		return err
	})
}

// OpenFile decrypts a SealFile output into dst, or copies an unsealed
// file as is, so callers can ask for a password on ErrPasswordRequired.
func OpenFile(src, dst string, password []byte) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	var magic [len(backupMagic)]byte
	n, err := io.ReadFull(in, magic[:])
	var r io.Reader = io.MultiReader(bytes.NewReader(magic[:n]), in)
	if err == nil && string(magic[:]) == backupMagic {
		var key []byte
		if r, key, err = openStream(in, password); err != nil {
			return err
		}
		defer clear(key)
	}
	return writeFileAtomic(dst, 0600, func(w io.Writer) error {
		_, err := io.Copy(w, r)
		return err
	})
}

// AccountBackup is the portable form of an account, readable on
// another device: plain JSON, or sealed under a password when one is
// given. It carries the private key.
type AccountBackup struct {
	Version  int             `json:"v"`
	Kind     string          `json:"kind"`
	Identity json.RawMessage `json:"identity"`
	Roster   json.RawMessage `json:"roster,omitempty"`
	Profile  json.RawMessage `json:"profile,omitempty"`
	Avatar   []byte          `json:"avatar,omitempty"`
}

const (
	accountKind     = "tincan-account"
	maxAccountBytes = 16 << 20
)

func (b *AccountBackup) wipe() {
	clear(b.Identity)
	clear(b.Roster)
	clear(b.Profile)
}

// ExportAccount decrypts the account files into one file, sealed under
// password unless it is empty.
func (v *Vault) ExportAccount(dst string, password []byte) error {
	identity, err := v.ReadFile(filepath.Join(v.dir, identityFile))
	if err != nil {
		return fmt.Errorf("no identity to export: %w", err)
	}
	b := AccountBackup{Version: 1, Kind: accountKind, Identity: identity}
	defer b.wipe()
	// A missing file is an empty one; one that won't open would be lost
	// on import, so it fails the export.
	if b.Roster, err = v.ReadFile(filepath.Join(v.dir, rosterFile)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("contacts: %w", err)
	}
	if b.Profile, err = v.ReadFile(filepath.Join(v.dir, profileFile)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("profile: %w", err)
	}
	if path := v.selfAvatar(); path != "" {
		if b.Avatar, err = v.ReadMedia(path); err != nil {
			return fmt.Errorf("profile picture: %w", err)
		}
	}
	j, err := json.MarshalIndent(b, "", "\t")
	if err != nil {
		return err
	}
	defer clear(j)
	if len(password) == 0 {
		return writeBytesAtomic(dst, 0600, j)
	}
	return sealStream(dst, password, writeAll(j))
}

// readAccount loads and checks a backup without touching the vault.
func readAccount(src string, password []byte) (*AccountBackup, error) {
	f, err := os.Open(src)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var magic [len(backupMagic)]byte
	n, _ := io.ReadFull(f, magic[:])
	var r io.Reader = io.MultiReader(bytes.NewReader(magic[:n]), f)
	if string(magic[:n]) == backupMagic {
		var key []byte
		if r, key, err = openStream(f, password); err != nil {
			return nil, err
		}
		defer clear(key)
	}
	j, err := io.ReadAll(io.LimitReader(r, maxAccountBytes+1))
	defer clear(j)
	if err != nil {
		return nil, err
	}
	if len(j) > maxAccountBytes {
		return nil, errors.New("account file too large")
	}
	b := new(AccountBackup)
	if err := json.Unmarshal(j, b); err != nil || b.Kind != accountKind || len(b.Identity) == 0 {
		b.wipe()
		return nil, errors.New("not a tincan account file")
	}
	var pk tailcat.PrivateKey
	if err := json.Unmarshal(b.Identity, &pk); err != nil || pk.Private.IsZero() {
		b.wipe()
		return nil, errors.New("account file has no usable key")
	}
	pk.Private = key.NodePrivate{}
	if len(b.Roster) > 0 && json.Unmarshal(b.Roster, new(rosterData)) != nil {
		b.wipe()
		return nil, errors.New("account file has a damaged contact list")
	}
	if len(b.Profile) > 0 && json.Unmarshal(b.Profile, new(storedProfile)) != nil {
		b.wipe()
		return nil, errors.New("account file has a damaged profile")
	}
	if len(b.Avatar) > maxAvatarBytes || len(b.Avatar) > 0 && checkAvatar(b.Avatar) != nil {
		b.Avatar = nil // not worth refusing the account over
	}
	return b, nil
}

// ImportAccount replaces the account with a backup, re-encrypted under
// this device's key. Everything is checked and staged first, and the
// swap rolls back on failure, so a bad import keeps the current account.
func (v *Vault) ImportAccount(src string, password []byte) error {
	b, err := readAccount(src, password)
	if err != nil {
		return err
	}
	defer b.wipe()
	var staged [][2]string // temp, final
	defer func() {
		for _, s := range staged {
			os.Remove(s[0])
		}
	}()
	// What the backup lacks belonged to the account being replaced.
	var drop []string
	for _, f := range []struct {
		name string
		data []byte
	}{
		{identityFile, b.Identity},
		{rosterFile, b.Roster},
		{profileFile, b.Profile},
	} {
		path := filepath.Join(v.dir, f.name)
		if len(f.data) == 0 {
			drop = append(drop, path)
			continue
		}
		blob, err := v.sealState(path, f.data)
		if err != nil {
			return err
		}
		tmp, err := stageFile(path, 0600, writeAll(blob))
		if err != nil {
			return err
		}
		staged = append(staged, [2]string{tmp, path})
	}
	avatar := ""
	if len(b.Avatar) > 0 {
		if avatar, err = v.avatarPath(selfOwner, b.Avatar); err != nil {
			return err
		}
		tmp, err := v.stageMedia(avatar, 0600, writeAll(b.Avatar))
		if err != nil {
			return err
		}
		staged = append(staged, [2]string{tmp, avatar})
	}
	if err := v.swapIn(staged, drop); err != nil {
		return err
	}
	staged = nil
	v.dropAvatars(selfOwner, avatar)
	return nil
}

// An import moves the files it replaces aside under a journal, so a
// failure or a crash midway puts them back.

const importJournal = "import.journal"

type journalEntry struct {
	Path string `json:"path"` // relative to the state dir
	Had  bool   `json:"had"`  // an old file was there to restore
}

func asidePath(path string) string {
	return filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp-import")
}

// swapIn renames each staged temp over its final path and removes drop,
// all or nothing.
func (v *Vault) swapIn(staged [][2]string, drop []string) error {
	targets := slices.Clone(drop)
	for _, s := range staged {
		targets = append(targets, s[1])
	}
	var entries []journalEntry
	for _, t := range targets {
		rel, err := filepath.Rel(v.dir, t)
		if err != nil {
			return err
		}
		_, err = os.Lstat(t)
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		entries = append(entries, journalEntry{Path: filepath.ToSlash(rel), Had: err == nil})
	}
	j, err := json.Marshal(entries)
	if err != nil {
		return err
	}
	if err := writeBytesAtomic(filepath.Join(v.dir, importJournal), 0600, j); err != nil {
		return err
	}
	err = func() error {
		for i, t := range targets {
			if entries[i].Had {
				if err := os.Rename(t, asidePath(t)); err != nil {
					return err
				}
			}
		}
		for _, s := range staged {
			if err := os.Rename(s[0], s[1]); err != nil {
				return err
			}
		}
		return nil
	}()
	if err != nil {
		if rerr := rollbackImport(v.dir); rerr != nil {
			return fmt.Errorf("%w; restoring the old account: %v", err, rerr)
		}
		return err
	}
	if err := os.Remove(filepath.Join(v.dir, importJournal)); err != nil {
		return err
	}
	for i, t := range targets {
		if entries[i].Had {
			os.Remove(asidePath(t))
		}
	}
	return nil
}

// rollbackImport undoes an import that a journal shows unfinished.
func rollbackImport(stateDir string) error {
	journal := filepath.Join(stateDir, importJournal)
	j, err := os.ReadFile(journal)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var entries []journalEntry
	if err := json.Unmarshal(j, &entries); err != nil {
		return err
	}
	for _, e := range entries {
		t := filepath.Join(stateDir, filepath.FromSlash(e.Path))
		if !filepath.IsLocal(e.Path) {
			continue
		}
		if !e.Had {
			err = os.Remove(t)
		} else if err = os.Rename(asidePath(t), t); errors.Is(err, fs.ErrNotExist) {
			err = nil // never moved aside
		}
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
	}
	return os.Remove(journal)
}

// ImportMedia seals a plaintext file into dir under a free variant of
// name, streaming it, and returns where it landed.
func (v *Vault) ImportMedia(src, dir, name string) (string, error) {
	in, err := os.Open(src)
	if err != nil {
		return "", err
	}
	defer in.Close()
	f, final, err := createUnique(dir, sanitizeName(name))
	if err != nil {
		return "", err
	}
	cw := v.ChunkWriter(f)
	if _, err = io.Copy(cw, in); err == nil {
		err = cw.Close()
	}
	if err != nil {
		f.Close()
		os.Remove(final + ".part")
		return "", err
	}
	return final, commitPart(f, final)
}
