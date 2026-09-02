package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
)

// Profile pictures live in StateDir/avatars named by owner and content,
// so a new picture gets a new path and nothing caching the old one by
// path can show it stale. The owner prefix finds the file it replaces.

const (
	selfOwner        = "self" // never a node key, so it can't collide
	legacyAvatarFile = "avatar.img"
)

func ownerPrefix(owner string) string {
	sum := sha256.Sum256([]byte(owner))
	return hex.EncodeToString(sum[:8])
}

func (v *Vault) avatarGlob(owner string) string {
	return filepath.Join(v.dir, "avatars", ownerPrefix(owner)+"-*.img")
}

// storeAvatar seals img as owner's picture unless it is already there,
// and removes the one it replaces. Empty img removes it. Returns the
// path, or "" when there is no picture.
func (v *Vault) storeAvatar(owner string, img []byte) (string, error) {
	path := ""
	if len(img) > 0 {
		sum := sha256.Sum256(img)
		path = filepath.Join(v.dir, "avatars", ownerPrefix(owner)+"-"+hex.EncodeToString(sum[:4])+".img")
		if _, err := os.Stat(path); err != nil {
			if err := v.WriteMedia(path, img, 0600); err != nil {
				return "", err
			}
		}
	}
	old, _ := filepath.Glob(v.avatarGlob(owner))
	if owner == selfOwner {
		old = append(old, filepath.Join(v.dir, legacyAvatarFile))
	}
	for _, f := range old {
		if f != path {
			os.Remove(f)
		}
	}
	return path, nil
}

// selfAvatar is the path of our own picture, or "" if there is none.
func (v *Vault) selfAvatar() string {
	if found, _ := filepath.Glob(v.avatarGlob(selfOwner)); len(found) > 0 {
		return found[0]
	}
	legacy := filepath.Join(v.dir, legacyAvatarFile)
	if _, err := os.Stat(legacy); err == nil {
		return legacy
	}
	return ""
}
