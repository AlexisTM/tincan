package bridge

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestSanitizeName(t *testing.T) {
	for in, want := range map[string]string{
		"../../etc/passwd":  "passwd",
		`..\..\evil.exe`:    "evil.exe",
		".hidden":           "hidden",
		"":                  "file",
		"ridge-north.jpg":   "ridge-north.jpg",
		"/abs/path/vid.mp4": "vid.mp4",
	} {
		if got := sanitizeName(in); got != want {
			t.Errorf("sanitizeName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSanitizeNameStripsHiddenChars(t *testing.T) {
	for in, want := range map[string]string{
		"a\x00b.txt":      "ab.txt",
		"evil‮gnp.exe":    "evilgnp.exe",
		"tab\there\n.jpg": "tabhere.jpg",
		"⁦x⁩.png":         "x.png",
		"bad\xffutf8.bin": "badutf8.bin",
		"\x00‏":           "file",
	} {
		if got := sanitizeName(in); got != want {
			t.Errorf("sanitizeName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSweepStale(t *testing.T) {
	dir := t.TempDir()
	old := time.Now().Add(-8 * 24 * time.Hour)
	files := map[string]bool{ // name -> survives
		".partial/abc.part":   false,
		"photo.jpg.part":      false,
		".chats.json.tmp123":  false,
		"photo.jpg":           true,
		".partial/fresh.part": true,
	}
	for name := range files {
		p := filepath.Join(dir, name)
		os.MkdirAll(filepath.Dir(p), 0700)
		os.WriteFile(p, []byte("x"), 0600)
		if name != ".partial/fresh.part" {
			os.Chtimes(p, old, old)
		}
	}
	sweepStale(dir)
	for name, survives := range files {
		_, err := os.Stat(filepath.Join(dir, name))
		if (err == nil) != survives {
			t.Errorf("%s: exists %v, want %v", name, err == nil, survives)
		}
	}
}
