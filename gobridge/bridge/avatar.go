package bridge

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"path/filepath"

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

func ownerPrefix(owner string) string {
	sum := sha256.Sum256([]byte(owner))
	return hex.EncodeToString(sum[:8])
}

func (v *Vault) avatarGlob(owner string) string {
	return filepath.Join(v.dir, "avatars", ownerPrefix(owner)+"-*.img")
}

func (v *Vault) avatarPath(owner string, img []byte) string {
	sum := sha256.Sum256(img)
	return filepath.Join(v.dir, "avatars", ownerPrefix(owner)+"-"+hex.EncodeToString(sum[:4])+".img")
}

// dropAvatars removes owner's pictures other than keep.
func (v *Vault) dropAvatars(owner, keep string) {
	old, _ := filepath.Glob(v.avatarGlob(owner))
	for _, f := range old {
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
		path = v.avatarPath(owner, img)
		if _, err := os.Stat(path); err != nil {
			if err := v.WriteMedia(path, img, 0600); err != nil {
				return "", err
			}
		}
	}
	v.dropAvatars(owner, path)
	return path, nil
}

// selfAvatar is the path of our own picture, or "" if there is none.
func (v *Vault) selfAvatar() string {
	if found, _ := filepath.Glob(v.avatarGlob(selfOwner)); len(found) > 0 {
		return found[0]
	}
	return ""
}
