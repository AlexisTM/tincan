package bridge

import (
	"bytes"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var buf bytes.Buffer
	if err := writeMsgFrame(&buf, &wireMsg{T: "profile", ID: "m1", Body: "hi", Avatar: []byte{9, 8}}); err != nil {
		t.Fatal(err)
	}
	if err := writeBlobFrame(&buf, "xfer-1", []byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}

	kind, payload, err := readFrame(&buf)
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

	kind, payload, err = readFrame(&buf)
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
