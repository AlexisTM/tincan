package bridge

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"tailscale.com/types/key"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := writeMsgFrame(&buf, &wireMsg{T: "profile", ID: "m1", Body: "hi", Avatar: []byte{9, 8}}); err != nil {
		t.Fatal(err)
	}
	if err := writeBlobFrame(&buf, "xfer-1", []byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}

	kind, payload, err := readFrame(&buf, maxFrame)
	if err != nil {
		t.Fatal(err)
	}
	if kind != frameMsg {
		t.Fatalf("message frame kind = %d", kind)
	}
	msg, err := parseMsg(payload)
	if err != nil {
		t.Fatal(err)
	}
	if msg.T != "profile" || msg.Body != "hi" || !bytes.Equal(msg.Avatar, []byte{9, 8}) {
		t.Fatalf("round-tripped message = %+v", msg)
	}

	kind, payload, err = readFrame(&buf, maxFrame)
	if err != nil {
		t.Fatal(err)
	}
	if kind != frameBlob {
		t.Fatalf("blob frame kind = %d", kind)
	}
	id, chunk, err := splitBlob(payload)
	if err != nil {
		t.Fatal(err)
	}
	if id != "xfer-1" || !bytes.Equal(chunk, []byte{1, 2, 3}) {
		t.Fatalf("blob = id %q chunk %v", id, chunk)
	}
}

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

func TestNegotiate(t *testing.T) {
	for _, c := range []struct {
		h  wireMsg
		ok bool
	}{
		{wireMsg{V: 1}, false},
		{wireMsg{V: 2}, true},
		{wireMsg{V: 2, VMin: 2, VMax: 5}, true},
		{wireMsg{V: 3, VMin: 3, VMax: 4}, false},
	} {
		if err := negotiate(&c.h); (err == nil) != c.ok {
			t.Errorf("negotiate(%+v) = %v, want ok %v", c.h, err, c.ok)
		}
	}
}

func TestFingerprintIsSymmetric(t *testing.T) {
	a, b := key.NewNode().Public().String(), key.NewNode().Public().String()
	fa, fb := fingerprint(a, b), fingerprint(b, a)
	if fa != fb {
		t.Fatalf("sides disagree: %q vs %q", fa, fb)
	}
	if !regexp.MustCompile(`^\d{4}( \d{4}){4}$`).MatchString(fa) {
		t.Fatalf("fingerprint %q is not 5 groups of 4 digits", fa)
	}
	if fingerprint(a, key.NewNode().Public().String()) == fa {
		t.Fatal("different pairs share a fingerprint")
	}
}

func TestParseRelay(t *testing.T) {
	for in, want := range map[string][2]string{
		"derp.example.com":              {"derp.example.com", ""},
		" https://example.com/map.json": {"", "https://example.com/map.json"},
		"http://x/m":                    {"", "http://x/m"},
		"":                              {"", ""},
	} {
		if h, u := ParseRelay(in); h != want[0] || u != want[1] {
			t.Errorf("ParseRelay(%q) = %q, %q", in, h, u)
		}
	}
}

func TestEventsCoalesceButNeverDropMessages(t *testing.T) {
	m := New(Config{})
	for range 5 {
		m.emit(map[string]any{"type": "peer-status", "peer": "q"})
	}
	for i := range maxLossyQueued + 10 {
		m.emit(map[string]any{"type": "file-progress", "peer": "p", "done": i})
	}
	m.emit(map[string]any{"type": "message", "peer": "p", "id": "m1"})
	m.emit(map[string]any{"type": "peer-request", "peer": "r", "first": ""})
	m.emit(map[string]any{"type": "peer-request", "peer": "r", "first": "hi"})
	m.emit(map[string]any{"type": "peer-added", "peer": "r"})

	counts := map[string]int{}
	deadline := time.Now().Add(2 * coalesceEvery)
	for time.Now().Before(deadline) {
		j, ok := m.NextEventTimeout(100*time.Millisecond, nil)
		if !ok {
			continue
		}
		var ev map[string]any
		json.Unmarshal([]byte(j), &ev)
		counts[ev["type"].(string)]++
	}
	if counts["file-progress"] != maxLossyQueued-1 || counts["message"] != 1 {
		t.Errorf("progress %d, messages %d", counts["file-progress"], counts["message"])
	}
	if counts["peer-status"] != 2 {
		t.Errorf("5 quick statuses became %d events, want first + latest", counts["peer-status"])
	}
	if counts["peer-request"] != 1 || counts["peer-added"] != 1 {
		t.Errorf("held request outlived its answer: %v", counts)
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
