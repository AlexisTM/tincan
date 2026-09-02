package bridge

import (
	"bytes"
	"crypto/rand"
	"crypto/subtle"
	"os"
	"path/filepath"
	"testing"
)

// Equal reports whether two vaults hold the same key.
func (v *Vault) Equal(o *Vault) bool {
	return subtle.ConstantTimeCompare(v.key, o.key) == 1
}

func TestVaultRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if err := CreateVault(dir, "hunter2", "password"); err != nil {
		t.Fatal(err)
	}
	if exists, mode, err := VaultExists(dir); !exists || mode != "password" || err != nil {
		t.Fatalf("VaultExists = %v %q %v", exists, mode, err)
	}
	if err := CreateVault(dir, "other", "password"); err == nil {
		t.Error("creating a second vault over the first should fail")
	}

	v, err := OpenVault(dir, "hunter2")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := OpenVault(dir, "wrong"); err == nil {
		t.Fatal("a wrong password should not open the vault")
	}

	path := filepath.Join(dir, "secret.json")
	if err := v.WriteFile(path, []byte(`{"hello":"world"}`), 0600); err != nil {
		t.Fatal(err)
	}
	onDisk, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(onDisk, []byte("hello")) {
		t.Error("plaintext readable on disk")
	}
	back, err := v.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(back) != `{"hello":"world"}` {
		t.Errorf("read back %q", back)
	}
}

func TestVaultChangeSecretKeepsData(t *testing.T) {
	dir := t.TempDir()
	if err := CreateVault(dir, "old", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(dir, "old")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "x")
	if err := v.WriteFile(path, []byte("keep me"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := v.ChangeSecret("device-secret", "device"); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenVault(dir, "old"); err == nil {
		t.Error("the old secret should stop working")
	}
	v2, err := OpenVault(dir, "device-secret")
	if err != nil {
		t.Fatal(err)
	}
	if !v.Equal(v2) {
		t.Error("rewrapping changed the data key")
	}
	back, err := v2.ReadFile(path)
	if err != nil || string(back) != "keep me" {
		t.Fatalf("data lost: %q %v", back, err)
	}
}

func TestVaultChunkedMedia(t *testing.T) {
	dir := t.TempDir()
	if err := CreateVault(dir, "pw", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(dir, "pw")
	if err != nil {
		t.Fatal(err)
	}

	blob := make([]byte, 3*chunkSize+1234)
	rand.Read(blob)

	sealed := filepath.Join(dir, "video.mp4")
	f, err := os.Create(sealed)
	if err != nil {
		t.Fatal(err)
	}
	w := v.ChunkWriter(f)
	for off := 0; off < len(blob); off += chunkSize {
		end := min(off+chunkSize, len(blob))
		if _, err := w.Write(blob[off:end]); err != nil {
			t.Fatal(err)
		}
	}
	f.Close()

	onDisk, err := os.ReadFile(sealed)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(onDisk, blob[:64]) {
		t.Error("plaintext readable on disk")
	}

	out := filepath.Join(dir, "out.mp4")
	if err := v.DecryptFile(sealed, out); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, blob) {
		t.Errorf("decrypted %d bytes, sent %d", len(got), len(blob))
	}
}

func TestVaultImportMediaStreams(t *testing.T) {
	dir := t.TempDir()
	if err := CreateVault(dir, "pw", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(dir, "pw")
	if err != nil {
		t.Fatal(err)
	}
	blob := make([]byte, 2*chunkSize+77)
	rand.Read(blob)
	src := filepath.Join(dir, "plain.bin")
	if err := os.WriteFile(src, blob, 0600); err != nil {
		t.Fatal(err)
	}
	media := filepath.Join(dir, "media")
	dst, err := v.ImportMedia(src, media, "sealed.bin")
	if err != nil {
		t.Fatal(err)
	}
	if again, err := v.ImportMedia(src, media, "sealed.bin"); err != nil || again == dst {
		t.Errorf("second import landed at %q (err %v), first at %q", again, err, dst)
	}
	if size, err := v.MediaSize(dst); err != nil || size != int64(len(blob)) {
		t.Errorf("MediaSize = %d (err %v), want %d", size, err, len(blob))
	}
	got, err := v.ReadMedia(dst)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, blob) {
		t.Errorf("read back %d bytes, imported %d", len(got), len(blob))
	}
}

func TestVaultNoneStillNeedsItsSecret(t *testing.T) {
	dir := t.TempDir()
	if err := CreateVault(dir, "", "none"); err == nil {
		t.Fatal("an unlocked vault still needs a keystore secret")
	}
	if err := CreateVault(dir, "keystore-secret", "none"); err != nil {
		t.Fatal(err)
	}
	if exists, mode, err := VaultExists(dir); !exists || mode != "none" || err != nil {
		t.Fatalf("VaultExists = %v %q %v", exists, mode, err)
	}
	if _, err := OpenVault(dir, ""); err == nil {
		t.Error("the files alone should not open the vault")
	}
	if _, err := OpenVault(dir, "keystore-secret"); err != nil {
		t.Fatal(err)
	}
}

func TestVaultUnreadableHeaderIsNotAbsent(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, vaultFile), []byte("{trunc"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := VaultExists(dir); err == nil {
		t.Error("a corrupt header should be reported, not taken for no vault")
	}
	if err := CreateVault(dir, "s", "password"); err == nil {
		t.Error("setup must not overwrite a header it can't read")
	}
}

func TestChunkWriterSplitsOversizedWrites(t *testing.T) {
	dir := t.TempDir()
	if err := CreateVault(dir, "s", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(dir, "s")
	if err != nil {
		t.Fatal(err)
	}
	big := make([]byte, 3*maxSealedChunk)
	rand.Read(big)
	path := filepath.Join(dir, "big.img")
	if err := v.WriteMedia(path, big, 0600); err != nil {
		t.Fatal(err)
	}
	got, err := v.ReadMedia(path)
	if err != nil || !bytes.Equal(got, big) {
		t.Fatalf("read back %d bytes (err %v), wrote %d", len(got), err, len(big))
	}
}

func TestImportAccountDropsWhatBackupLacks(t *testing.T) {
	open := func() *Vault {
		dir := t.TempDir()
		if err := CreateVault(dir, "s", "password"); err != nil {
			t.Fatal(err)
		}
		v, err := OpenVault(dir, "s")
		if err != nil {
			t.Fatal(err)
		}
		if err := v.WriteFile(filepath.Join(dir, identityFile), []byte(`{}`), 0600); err != nil {
			t.Fatal(err)
		}
		return v
	}
	bare, full := open(), open()
	for _, f := range []string{rosterFile, profileFile} {
		if err := full.WriteFile(filepath.Join(full.dir, f), []byte(`{}`), 0600); err != nil {
			t.Fatal(err)
		}
	}
	avatar, err := full.storeAvatar(selfOwner, []byte("img"))
	if err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(t.TempDir(), "account.json")
	if err := bare.ExportAccount(backup); err != nil {
		t.Fatal(err)
	}
	if err := full.ImportAccount(backup); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{filepath.Join(full.dir, rosterFile), filepath.Join(full.dir, profileFile), avatar} {
		if _, err := os.Stat(f); !os.IsNotExist(err) {
			t.Errorf("%s from the replaced account survived the import", f)
		}
	}
}

func TestCreateUniqueLongName(t *testing.T) {
	dir := t.TempDir()
	name := string(bytes.Repeat([]byte("é"), 150)) + ".jpg"
	for range 2 {
		f, final, err := createUnique(dir, name)
		if err != nil {
			t.Fatal(err)
		}
		if err := commitPart(f, final); err != nil {
			t.Fatal(err)
		}
		if base := filepath.Base(final); filepath.Ext(base) != ".jpg" || len(base) > maxNameBytes+8 {
			t.Fatalf("got %q", base)
		}
	}
}
