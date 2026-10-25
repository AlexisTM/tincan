package bridge

import (
	"bytes"
	"regexp"
	"testing"

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
