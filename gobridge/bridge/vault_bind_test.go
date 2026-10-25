package bridge

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"github.com/tailscale/tailcat"
)

func testIdentity(t *testing.T) []byte {
	t.Helper()
	j, err := json.Marshal(tailcat.NewPrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	return j
}

func newTestVault(t *testing.T) *Vault {
	t.Helper()
	dir := t.TempDir()
	if err := CreateVault(dir, "pw", "device"); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(dir, "pw")
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// chunkOffsets lists where each sealed chunk record starts.
func chunkOffsets(t *testing.T, b []byte) []int {
	t.Helper()
	var offs []int
	off := len(mediaMagic) + mediaIDSize
	for off < len(b) {
		offs = append(offs, off)
		n, err := readLen(bytes.NewReader(b[off:]), maxSealedChunk)
		if err != nil {
			t.Fatal(err)
		}
		off += 4 + int(n)
	}
	return append(offs, off)
}

func TestVaultStateFileBoundToPath(t *testing.T) {
	v := newTestVault(t)
	a, b := filepath.Join(v.dir, "a.json"), filepath.Join(v.dir, "b.json")
	for _, p := range []string{a, b} {
		if err := v.WriteFile(p, []byte(p), 0600); err != nil {
			t.Fatal(err)
		}
	}
	blob, _ := os.ReadFile(a)
	os.WriteFile(b, blob, 0600)
	if _, err := v.ReadFile(b); err == nil {
		t.Error("a file renamed over another should not open")
	}
}

func TestVaultMediaTruncationDetected(t *testing.T) {
	v := newTestVault(t)
	path := filepath.Join(v.dir, "m")
	if err := v.WriteMedia(path, make([]byte, 2*chunkSize), 0600); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	offs := chunkOffsets(t, b)
	for _, cut := range offs[1 : len(offs)-1] {
		os.WriteFile(path, b[:cut], 0600)
		if _, err := v.ReadMedia(path); !errors.Is(err, errTruncated) {
			t.Errorf("cut at %d: err %v, want truncated", cut, err)
		}
	}
}

func TestVaultMediaChunkSwapDetected(t *testing.T) {
	v := newTestVault(t)
	path := filepath.Join(v.dir, "m")
	data := make([]byte, 2*chunkSize)
	rand.Read(data)
	if err := v.WriteMedia(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(path)
	o := chunkOffsets(t, b)
	var swapped []byte
	swapped = append(swapped, b[:o[0]]...)
	swapped = append(swapped, b[o[1]:o[2]]...)
	swapped = append(swapped, b[o[0]:o[1]]...)
	swapped = append(swapped, b[o[2]:]...)
	os.WriteFile(path, swapped, 0600)
	if _, err := v.ReadMedia(path); err == nil {
		t.Error("reordered chunks should not open")
	}
}

func TestVaultMediaChunkFromOtherFileDetected(t *testing.T) {
	v := newTestVault(t)
	a, b := filepath.Join(v.dir, "a"), filepath.Join(v.dir, "b")
	for _, p := range []string{a, b} {
		if err := v.WriteMedia(p, make([]byte, chunkSize+10), 0600); err != nil {
			t.Fatal(err)
		}
	}
	ab, _ := os.ReadFile(a)
	bb, _ := os.ReadFile(b)
	oa, ob := chunkOffsets(t, ab), chunkOffsets(t, bb)
	mixed := append(append([]byte{}, bb[:ob[0]]...), ab[oa[0]:oa[1]]...)
	mixed = append(mixed, bb[ob[1]:]...)
	os.WriteFile(b, mixed, 0600)
	if _, err := v.ReadMedia(b); err == nil {
		t.Error("a chunk spliced from another file should not open")
	}
}

func TestVaultLegacyFormatStillReadable(t *testing.T) {
	dir := t.TempDir()
	dek := make([]byte, 32)
	rand.Read(dek)
	if err := writeHeader(dir, "pw", "password", dek, 1); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(dir, "pw")
	if err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(dir, "s.json")
	old, _ := seal(dek, []byte("old state"), nil)
	os.WriteFile(state, old, 0600)
	if got, err := v.ReadFile(state); err != nil || string(got) != "old state" {
		t.Fatalf("v1 state: %q %v", got, err)
	}
	if err := v.WriteFile(state, []byte("new state"), 0600); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(state); !bytes.HasPrefix(b, []byte(stateMagic)) {
		t.Error("a write should upgrade the file format")
	}

	var media bytes.Buffer
	for _, part := range []string{"hello ", "world"} {
		blob, _ := seal(dek, []byte(part), nil)
		writeLenPrefixed(&media, blob)
	}
	mpath := filepath.Join(dir, "m")
	os.WriteFile(mpath, media.Bytes(), 0600)
	if got, err := v.ReadMedia(mpath); err != nil || string(got) != "hello world" {
		t.Fatalf("v1 media: %q %v", got, err)
	}
	if n, err := v.MediaSize(mpath); err != nil || n != 11 {
		t.Errorf("v1 MediaSize = %d %v", n, err)
	}

	fresh := newTestVault(t)
	os.WriteFile(filepath.Join(fresh.dir, "m"), media.Bytes(), 0600)
	if _, err := fresh.ReadMedia(filepath.Join(fresh.dir, "m")); err == nil {
		t.Error("a v2 vault should refuse unbound media")
	}
}

func TestVaultResumePart(t *testing.T) {
	v := newTestVault(t)
	data := make([]byte, 3*chunkSize+99)
	rand.Read(data)
	part := filepath.Join(v.dir, "x.part")
	f, _ := os.Create(part)
	w := v.ChunkWriter(f)
	w.Write(data[:2*chunkSize+500]) // the 500 stay buffered, as on a dropped link
	f.Write([]byte{0, 0, 1})        // torn record
	f.Close()

	f, err := os.OpenFile(part, os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	w, have, err := v.ResumePart(f)
	if err != nil || have != 2*chunkSize {
		t.Fatalf("ResumePart = %d %v", have, err)
	}
	if _, err := w.Write(data[have:]); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	got, err := v.ReadMedia(part)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("resumed file reads back %d bytes, err %v", len(got), err)
	}
	if n, _ := v.MediaSize(part); n != int64(len(data)) {
		t.Errorf("MediaSize = %d", n)
	}
}

func TestVaultLock(t *testing.T) {
	v := newTestVault(t)
	path := filepath.Join(v.dir, "s")
	v.WriteFile(path, []byte("x"), 0600)
	v.Lock()
	if _, err := v.ReadFile(path); !errors.Is(err, errLocked) {
		t.Errorf("read after lock: %v", err)
	}
	if v.key != nil {
		t.Error("key kept after lock")
	}
}

func TestAccountBackupPassword(t *testing.T) {
	v := newTestVault(t)
	v.WriteFile(filepath.Join(v.dir, identityFile), testIdentity(t), 0600)
	backup := filepath.Join(t.TempDir(), "acct")
	if err := v.ExportAccount(backup, []byte("s3cret")); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(backup); bytes.Contains(b, []byte("identity")) {
		t.Error("sealed backup is readable")
	}
	other := newTestVault(t)
	if err := other.ImportAccount(backup, nil); !errors.Is(err, ErrPasswordRequired) {
		t.Errorf("no password: %v", err)
	}
	if err := other.ImportAccount(backup, []byte("nope")); !errors.Is(err, errWrongPassword) {
		t.Errorf("wrong password: %v", err)
	}
	if err := other.ImportAccount(backup, []byte("s3cret")); err != nil {
		t.Fatal(err)
	}
	a, _ := v.ReadFile(filepath.Join(v.dir, identityFile))
	b, err := other.ReadFile(filepath.Join(other.dir, identityFile))
	var ca, cb bytes.Buffer
	json.Compact(&ca, a)
	json.Compact(&cb, b)
	if err != nil || !bytes.Equal(ca.Bytes(), cb.Bytes()) {
		t.Errorf("identity not restored: %v", err)
	}
}

func TestImportAccountValidatesBeforeWriting(t *testing.T) {
	v := newTestVault(t)
	id := testIdentity(t)
	v.WriteFile(filepath.Join(v.dir, identityFile), id, 0600)
	for name, b := range map[string]AccountBackup{
		"zero key":   {Kind: accountKind, Identity: json.RawMessage(`{}`)},
		"bad roster": {Kind: accountKind, Identity: testIdentity(t), Roster: json.RawMessage(`[1]`)},
	} {
		j, _ := json.Marshal(b)
		src := filepath.Join(t.TempDir(), "acct")
		os.WriteFile(src, j, 0600)
		if err := v.ImportAccount(src, nil); err == nil {
			t.Errorf("%s: import accepted", name)
		}
		if got, _ := v.ReadFile(filepath.Join(v.dir, identityFile)); !bytes.Equal(got, id) {
			t.Errorf("%s: identity replaced", name)
		}
	}
}

func TestSealFileRoundTrip(t *testing.T) {
	dir := t.TempDir()
	data := make([]byte, chunkSize*2+3)
	rand.Read(data)
	src, sealed, out := filepath.Join(dir, "a"), filepath.Join(dir, "b"), filepath.Join(dir, "c")
	os.WriteFile(src, data, 0600)
	if err := SealFile(src, sealed, []byte("pw")); err != nil {
		t.Fatal(err)
	}
	if err := OpenFile(sealed, out, nil); !errors.Is(err, ErrPasswordRequired) {
		t.Errorf("no password: %v", err)
	}
	if err := OpenFile(sealed, out, []byte("bad")); !errors.Is(err, errWrongPassword) {
		t.Errorf("bad password: %v", err)
	}
	if err := OpenFile(sealed, out, []byte("pw")); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(out); !bytes.Equal(got, data) {
		t.Error("round trip changed the data")
	}
	if err := OpenFile(src, out, nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(out); !bytes.Equal(got, data) {
		t.Error("an unsealed file should copy through")
	}
	b, _ := os.ReadFile(sealed)
	os.WriteFile(sealed, b[:len(b)-50], 0600)
	if err := OpenFile(sealed, out, []byte("pw")); err == nil {
		t.Error("a truncated backup should not open")
	}
}

func TestCheckAvatar(t *testing.T) {
	encode := func(w, h int) []byte {
		var b bytes.Buffer
		png.Encode(&b, image.NewGray(image.Rect(0, 0, w, h)))
		return b.Bytes()
	}
	if err := checkAvatar(encode(64, 64)); err != nil {
		t.Errorf("small png: %v", err)
	}
	if err := checkAvatar(encode(maxAvatarSide+1, 1)); err == nil {
		t.Error("oversized png accepted")
	}
	if err := checkAvatar([]byte("not an image")); err == nil {
		t.Error("garbage accepted")
	}
}
