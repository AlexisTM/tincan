package bridge

import (
	"encoding/binary"
	"fmt"
	"io"

	"github.com/fxamacker/cbor/v2"
)

// Wire format, one TCP stream per peer: 4-byte big-endian length, then
// a 1-byte kind, then the payload. Message frames are CBOR, the codec
// the transport's address format already uses, so avatar bytes ride
// natively. Blob frames are file chunks behind a fixed-width transfer id.

const (
	ChatPort = 7223

	frameMsg  byte = 0 // CBOR wireMsg
	frameBlob byte = 1

	maxFrame      = 4 << 20
	chunkSize     = 256 << 10
	transferIDLen = 16

	// A stranger's frames are capped near the largest thing they may
	// send: a profile with a picture, its text capped by maxProfileText.
	maxPendingFrame = maxAvatarBytes + 64<<10

	// Texts, reactions and error reasons.
	maxBody = 64 << 10

	protoVersion = 2
	protoMin     = 2
)

// features this side speaks, offered in the hello.
var features = []string{"ack", "react", "reply", "resume", "timer"}

type wireMsg struct {
	T       string   `json:"t"`
	V       int      `json:"v,omitempty"`
	VMin    int      `json:"vmin,omitempty"`
	VMax    int      `json:"vmax,omitempty"`
	Feat    []string `json:"feat,omitempty"`
	Inst    string   `json:"inst,omitempty"` // random per process; tells two devices on one identity apart
	Name    string   `json:"name,omitempty"`
	Key     string   `json:"key,omitempty"`     // sender's stable identity (server node key)
	ConnKey string   `json:"connKey,omitempty"` // sender's WireGuard key on this connection
	Proof   []byte   `json:"proof,omitempty"`   // dialer's hello: helloProof sealed from Key to the server
	ID      string   `json:"id,omitempty"`
	TS      int64    `json:"ts,omitempty"`
	Body    string   `json:"body,omitempty"`
	File    string   `json:"file,omitempty"`
	Size    int64    `json:"size,omitempty"`
	Kind    string   `json:"kind,omitempty"`
	Ref     string   `json:"ref,omitempty"`   // ack, react, file-resume: the message it is about
	Reply   string   `json:"reply,omitempty"` // text: id of the quoted message
	Have    int64    `json:"have,omitempty"`  // file-resume: bytes already held; -1 refuses
	Code    string   `json:"code,omitempty"`  // error

	// profile messages
	SelfAddr string `json:"saddr,omitempty"` // sender's own connection token
	Desc     string `json:"desc,omitempty"`
	Status   string `json:"status,omitempty"`
	Avatar   []byte `json:"avatar,omitempty"` // image bytes, ≤ maxAvatarBytes

	// status: the dialer mirrors its measured path so both sides agree.
	Direct bool   `json:"direct,omitempty"`
	Addr   string `json:"addr,omitempty"`
	Relay  string `json:"relay,omitempty"`
	Ms     int    `json:"ms,omitempty"`
}

const maxAvatarBytes = 256 << 10

// Frames on the wire and sealed media chunks share one framing: a
// 4-byte big-endian length, then that many bytes.

// writeLenPrefixed writes parts as one record, in a single Write.
func writeLenPrefixed(w io.Writer, parts ...[]byte) error {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	buf := make([]byte, 4, 4+n)
	binary.BigEndian.PutUint32(buf, uint32(n))
	for _, p := range parts {
		buf = append(buf, p...)
	}
	_, err := w.Write(buf)
	return err
}

// readLen reads a record's length, refusing empty or over-max ones.
// A clean io.EOF means the stream ended between records.
func readLen(r io.Reader, max uint32) (uint32, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return 0, err
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n == 0 || n > max {
		return 0, fmt.Errorf("bad record length %d", n)
	}
	return n, nil
}

func readLenPrefixed(r io.Reader, max uint32) ([]byte, error) {
	n, err := readLen(r, max)
	if err != nil {
		return nil, err
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func writeFrame(w io.Writer, kind byte, payload []byte) error {
	if len(payload)+1 > maxFrame {
		return fmt.Errorf("frame too large: %d", len(payload))
	}
	return writeLenPrefixed(w, []byte{kind}, payload)
}

func encodeMsg(m *wireMsg) ([]byte, error) { return cbor.Marshal(m) }

func writeMsgFrame(w io.Writer, m *wireMsg) error {
	b, err := encodeMsg(m)
	if err != nil {
		return err
	}
	return writeFrame(w, frameMsg, b)
}

func parseMsg(payload []byte) (*wireMsg, error) {
	m := new(wireMsg)
	if err := cbor.Unmarshal(payload, m); err != nil {
		return nil, err
	}
	return m, nil
}

// writeBlobFrame writes one chunk of the transfer named id.
func writeBlobFrame(w io.Writer, id string, chunk []byte) error {
	if len(id) > transferIDLen {
		return fmt.Errorf("transfer id too long: %q", id)
	}
	payload := make([]byte, transferIDLen, transferIDLen+len(chunk))
	copy(payload, id)
	return writeFrame(w, frameBlob, append(payload, chunk...))
}

func readFrame(r io.Reader, max uint32) (kind byte, payload []byte, err error) {
	buf, err := readLenPrefixed(r, max)
	if err != nil {
		return 0, nil, err
	}
	return buf[0], buf[1:], nil
}

// splitBlob undoes writeBlobFrame's payload framing.
func splitBlob(payload []byte) (id string, chunk []byte, err error) {
	if len(payload) < transferIDLen {
		return "", nil, fmt.Errorf("short blob frame: %d bytes", len(payload))
	}
	idb := payload[:transferIDLen]
	for len(idb) > 0 && idb[len(idb)-1] == 0 {
		idb = idb[:len(idb)-1]
	}
	return string(idb), payload[transferIDLen:], nil
}
