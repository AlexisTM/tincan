package bridge

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
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

type vaultHeader struct {
	Version int    `json:"v"`
	KDF     string `json:"kdf"` // argon2id for passwords, hkdf for keystore secrets
	Salt    []byte `json:"salt"`
	Wrapped []byte `json:"wrapped"`
	Mode    string `json:"mode"` // password | device | none, for the UI
}

// Vault seals and opens files with the data key.
type Vault struct {
	key []byte
	dir string // the stateDir holding vault.json and the account files
}

// Argon2id parameters. 64 MiB is heavy enough to matter on a stolen
// phone and still unlocks in about a second on a slow one.
const (
	argonTime    = 3
	argonMemory  = 64 * 1024
	argonThreads = 4
)

func deriveKey(kdf, secret string, salt []byte) ([]byte, error) {
	switch kdf {
	case "argon2id":
		return argon2.IDKey([]byte(secret), salt, argonTime, argonMemory, argonThreads, 32), nil
	case "hkdf":
		// The secret is already 256 random bits; stretching it buys
		// nothing but unlock latency.
		key := make([]byte, 32)
		if _, err := io.ReadFull(hkdf.New(sha256.New, []byte(secret), salt, []byte("tincan vault")), key); err != nil {
			return nil, err
		}
		return key, nil
	}
	return nil, fmt.Errorf("unknown key derivation %q", kdf)
}

func seal(key, plaintext []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return aead.Seal(nonce, nonce, plaintext, nil), nil
}

func open(key, blob []byte) ([]byte, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	if len(blob) < aead.NonceSize() {
		return nil, errors.New("ciphertext truncated")
	}
	nonce, ct := blob[:aead.NonceSize()], blob[aead.NonceSize():]
	return aead.Open(nil, nonce, ct, nil)
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
func writeHeader(stateDir, secret, mode string, dek []byte) error {
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
	kek, err := deriveKey(kdf, secret, salt)
	if err != nil {
		return err
	}
	wrapped, err := seal(kek, dek)
	if err != nil {
		return err
	}
	j, err := json.MarshalIndent(
		vaultHeader{Version: 1, KDF: kdf, Salt: salt, Wrapped: wrapped, Mode: mode}, "", "\t")
	if err != nil {
		return err
	}
	return writeBytesAtomic(headerPath(stateDir), 0600, j)
}

// writeFileAtomic fills a temp file beside path and renames it over
// path, so a process killed mid-write (Android does this freely)
// leaves the old file whole rather than a truncated one.
func writeFileAtomic(path string, perm os.FileMode, fill func(w io.Writer) error) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp) // no-op once renamed
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
		return err
	}
	return os.Rename(tmp, path)
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
	name = capName(name)
	for {
		final := uniquePath(dir, name)
		f, err := os.OpenFile(final+".part", os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		return f, final, err
	}
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
	if _, err := rand.Read(dek); err != nil {
		return err
	}
	return writeHeader(stateDir, secret, mode, dek)
}

// OpenVault unwraps the data key. A wrong secret fails here.
func OpenVault(stateDir, secret string) (*Vault, error) {
	h, err := readHeader(stateDir)
	if err != nil {
		return nil, err
	}
	kek, err := deriveKey(h.KDF, secret, h.Salt)
	if err != nil {
		return nil, err
	}
	dek, err := open(kek, h.Wrapped)
	if err != nil {
		return nil, errors.New("wrong password")
	}
	return &Vault{key: dek, dir: stateDir}, nil
}

// ChangeSecret rewraps the same data key under a new secret, so
// switching between a password and biometrics leaves the data alone.
func (v *Vault) ChangeSecret(secret, mode string) error {
	return writeHeader(v.dir, secret, mode, v.key)
}

func (v *Vault) WriteFile(path string, data []byte, perm os.FileMode) error {
	blob, err := seal(v.key, data)
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
	return open(v.key, blob)
}

func (v *Vault) String() string {
	return "Vault(" + base64.RawStdEncoding.EncodeToString(v.key[:4]) + "…)"
}

// Media is sealed chunk by chunk as it arrives, so a received file is
// never plaintext on disk, not even briefly. Each chunk is a 4-byte
// big-endian length followed by nonce||ciphertext.

const maxSealedChunk = 1 << 20

type chunkWriter struct {
	v *Vault
	w io.Writer
}

// ChunkWriter seals each Write as one or more chunks of at most
// chunkSize, so a peer's oversized frame still reads back.
func (v *Vault) ChunkWriter(w io.Writer) io.Writer { return &chunkWriter{v: v, w: w} }

func (c *chunkWriter) Write(p []byte) (int, error) {
	for off := 0; off < len(p); off += chunkSize {
		blob, err := seal(c.v.key, p[off:min(off+chunkSize, len(p))])
		if err != nil {
			return off, err
		}
		if err := writeLenPrefixed(c.w, blob); err != nil {
			return off, err
		}
	}
	return len(p), nil
}

type chunkReader struct {
	v   *Vault
	r   io.Reader
	buf []byte
}

// ChunkReader opens what ChunkWriter sealed, as a plain byte stream.
func (v *Vault) ChunkReader(r io.Reader) io.Reader { return &chunkReader{v: v, r: r} }

func (c *chunkReader) Read(p []byte) (int, error) {
	for len(c.buf) == 0 {
		blob, err := readLenPrefixed(c.r, maxSealedChunk)
		if err != nil {
			return 0, err // a clean io.EOF only between chunks
		}
		plain, err := open(c.v.key, blob)
		if err != nil {
			return 0, err
		}
		c.buf = plain
	}
	n := copy(p, c.buf)
	c.buf = c.buf[n:]
	return n, nil
}

// createMedia writes path through a ChunkWriter filled by fill.
func (v *Vault) createMedia(path string, perm os.FileMode, fill func(w io.Writer) error) error {
	return writeFileAtomic(path, perm, func(w io.Writer) error { return fill(v.ChunkWriter(w)) })
}

// WriteMedia seals data in the chunked format, so images and files
// share one on-disk format and one decrypt path.
func (v *Vault) WriteMedia(path string, data []byte, perm os.FileMode) error {
	return v.createMedia(path, perm, func(w io.Writer) error {
		_, err := w.Write(data)
		return err
	})
}

// MediaSize is the plaintext size of a chunked file, read off the
// chunk headers without decrypting.
func (v *Vault) MediaSize(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	overhead := int64(chacha20poly1305.NonceSizeX + chacha20poly1305.Overhead)
	var size int64
	for {
		n, err := readLen(f, maxSealedChunk)
		if err == io.EOF {
			return size, nil
		}
		if err != nil {
			return 0, err
		}
		if int64(n) < overhead {
			return 0, fmt.Errorf("bad chunk length %d", n)
		}
		if _, err := f.Seek(int64(n), io.SeekCurrent); err != nil {
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

// AccountBackup is the portable form of an account: plaintext, because
// it has to be readable on another device. It carries the private key.
type AccountBackup struct {
	Version  int             `json:"v"`
	Kind     string          `json:"kind"`
	Identity json.RawMessage `json:"identity"`
	Roster   json.RawMessage `json:"roster,omitempty"`
	Profile  json.RawMessage `json:"profile,omitempty"`
	Avatar   []byte          `json:"avatar,omitempty"`
}

const accountKind = "tincan-account"

// ExportAccount decrypts the account files into one plaintext file.
func (v *Vault) ExportAccount(dst string) error {
	identity, err := v.ReadFile(filepath.Join(v.dir, identityFile))
	if err != nil {
		return fmt.Errorf("no identity to export: %w", err)
	}
	b := AccountBackup{Version: 1, Kind: accountKind, Identity: identity}
	if r, err := v.ReadFile(filepath.Join(v.dir, rosterFile)); err == nil {
		b.Roster = r
	}
	if p, err := v.ReadFile(filepath.Join(v.dir, profileFile)); err == nil {
		b.Profile = p
	}
	if path := v.selfAvatar(); path != "" {
		if a, err := v.ReadMedia(path); err == nil {
			b.Avatar = a
		}
	}
	j, err := json.MarshalIndent(b, "", "\t")
	if err != nil {
		return err
	}
	return os.WriteFile(dst, j, 0600)
}

// ImportAccount writes a backup back into the vault, re-encrypted under
// this device's key.
func (v *Vault) ImportAccount(src string) error {
	j, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	var b AccountBackup
	if err := json.Unmarshal(j, &b); err != nil || b.Kind != accountKind || len(b.Identity) == 0 {
		return errors.New("not a tincan account file")
	}
	if err := v.WriteFile(filepath.Join(v.dir, identityFile), b.Identity, 0600); err != nil {
		return err
	}
	// What the backup lacks belonged to the account being replaced.
	for _, f := range []struct {
		name string
		data []byte
	}{
		{rosterFile, b.Roster},
		{profileFile, b.Profile},
	} {
		path := filepath.Join(v.dir, f.name)
		var err error
		if len(f.data) > 0 {
			err = v.WriteFile(path, f.data, 0600)
		} else if err = os.Remove(path); errors.Is(err, os.ErrNotExist) {
			err = nil
		}
		if err != nil {
			return err
		}
	}
	_, err = v.storeAvatar(selfOwner, b.Avatar)
	return err
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
	// Full-size writes keep the chunks at chunkSize.
	bw := bufio.NewWriterSize(v.ChunkWriter(f), chunkSize)
	if _, err = io.Copy(bw, in); err == nil {
		err = bw.Flush()
	}
	if err != nil {
		f.Close()
		os.Remove(final + ".part")
		return "", err
	}
	return final, commitPart(f, final)
}
