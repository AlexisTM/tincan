package bridge

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"os"
	"path/filepath"

	"golang.org/x/crypto/hkdf"
	_ "golang.org/x/image/webp"
)

// Profile pictures live in StateDir/avatars named by owner and content,
// so a new picture gets a new path and nothing caching the old one by
// path can show it stale. The owner prefix finds the file it replaces.

const (
	selfOwner     = "self" // never a node key, so it can't collide
	maxAvatarSide = 2048
)

// checkAvatar reads just the image header, refusing formats we don't
// show and dimensions big enough to blow up a decoder.
func checkAvatar(img []byte) error {
	cfg, format, err := image.DecodeConfig(bytes.NewReader(img))
	if err != nil {
		return fmt.Errorf("not a supported image: %w", err)
	}
	switch format {
	case "png", "jpeg", "gif", "webp":
	default:
		return fmt.Errorf("unsupported image format %q", format)
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > maxAvatarSide || cfg.Height > maxAvatarSide {
		return fmt.Errorf("picture is %dx%d; limit is %dx%d", cfg.Width, cfg.Height, maxAvatarSide, maxAvatarSide)
	}
	return nil
}

// nameTag names a file after data under a key derived from the vault's,
// so a known picture or contact key can't be matched to a filename.
func (v *Vault) nameTag(kind string, data []byte, n int) (string, error) {
	var tag string
	err := v.withKey(func(key []byte) error {
		nk := make([]byte, 32)
		defer clear(nk)
		if _, err := io.ReadFull(hkdf.New(sha256.New, key, nil, []byte("tincan file names")), nk); err != nil {
			return err
		}
		mac := hmac.New(sha256.New, nk)
		mac.Write([]byte(kind + "\x00"))
		mac.Write(data)
		tag = hex.EncodeToString(mac.Sum(nil)[:n])
		return nil
	})
	return tag, err
}

// legacyOwnerPrefix is how pictures were named before nameTag.
func legacyOwnerPrefix(owner string) string {
	sum := sha256.Sum256([]byte(owner))
	return hex.EncodeToString(sum[:8])
}

// avatarFiles lists owner's pictures, under either naming.
func (v *Vault) avatarFiles(owner string) []string {
	var found []string
	prefixes := []string{legacyOwnerPrefix(owner)}
	if p, err := v.nameTag("owner", []byte(owner), 8); err == nil {
		prefixes = append([]string{p}, prefixes...)
	}
	for _, p := range prefixes {
		m, _ := filepath.Glob(filepath.Join(v.dir, "avatars", p+"-*.img"))
		found = append(found, m...)
	}
	return found
}

func (v *Vault) avatarPath(owner string, img []byte) (string, error) {
	op, err := v.nameTag("owner", []byte(owner), 8)
	if err != nil {
		return "", err
	}
	tag, err := v.nameTag("avatar", img, 16)
	if err != nil {
		return "", err
	}
	return filepath.Join(v.dir, "avatars", op+"-"+tag+".img"), nil
}

// dropAvatars removes owner's pictures other than keep.
func (v *Vault) dropAvatars(owner, keep string) {
	for _, f := range v.avatarFiles(owner) {
		if f != keep {
			os.Remove(f)
		}
	}
}

// storeAvatar seals img as owner's picture unless it is already there,
// and removes the one it replaces. Empty img removes it. Returns the
// path, or "" when there is no picture.
func (v *Vault) storeAvatar(owner string, img []byte) (string, error) {
	path := ""
	if len(img) > 0 {
		var err error
		if path, err = v.avatarPath(owner, img); err != nil {
			return "", err
		}
		if _, err := os.Stat(path); err != nil {
			if err := v.WriteMedia(path, img, 0600); err != nil {
				return "", err
			}
		}
	}
	v.dropAvatars(owner, path)
	if owner == selfOwner {
		os.Remove(filepath.Join(v.dir, legacyAvatarFile))
	}
	return path, nil
}

// legacyAvatarFile is where our own picture lived before avatars/.
const legacyAvatarFile = "avatar.img"

// selfAvatar is the path of our own picture, or "" if there is none.
func (v *Vault) selfAvatar() string {
	if found := v.avatarFiles(selfOwner); len(found) > 0 {
		return found[0]
	}
	if img, err := v.ReadMedia(filepath.Join(v.dir, legacyAvatarFile)); err == nil {
		if path, err := v.storeAvatar(selfOwner, img); err == nil {
			return path
		}
	}
	return ""
}
