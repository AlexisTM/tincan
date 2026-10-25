package bridge

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"image"
	"image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/derp/derpserver"
	"tailscale.com/net/stun"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
)

// devDERP runs a local DERP relay and STUN responder, as tailcat's own
// tests do, so none of this needs network.
func devDERP(t *testing.T, logf logger.Logf) *tailcfg.DERPRegion {
	t.Helper()
	d := derpserver.New(key.NewNode(), logf)
	ln, err := net.Listen("tcp", "localhost:0")
	if err != nil {
		t.Fatal(err)
	}
	httpsrv := httptest.NewUnstartedServer(derpserver.Handler(d))
	httpsrv.Listener = ln
	httpsrv.Config.ErrorLog = logger.StdLogger(logf)
	httpsrv.Config.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
	httpsrv.StartTLS()
	t.Cleanup(httpsrv.Close)

	uln, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { uln.Close() })
	go func() {
		var buf [1500]byte
		for {
			n, src, err := uln.ReadFromUDPAddrPort(buf[:])
			if err != nil {
				return
			}
			txid, err := stun.ParseBindingRequest(buf[:n])
			if err != nil {
				continue
			}
			uln.WriteToUDPAddrPort(stun.Response(txid, src), src)
		}
	}()

	return &tailcfg.DERPRegion{
		RegionID:   1,
		RegionCode: "D",
		Nodes: []*tailcfg.DERPNode{{
			Name:             "t1",
			RegionID:         1,
			HostName:         "T",
			IPv4:             "127.0.0.1",
			IPv6:             "none",
			STUNPort:         uln.LocalAddr().(*net.UDPAddr).Port,
			DERPPort:         httpsrv.Listener.Addr().(*net.TCPAddr).Port,
			InsecureForTests: true,
		}},
	}
}

func newTestManager(t *testing.T, name string, reg *tailcfg.DERPRegion) *Manager {
	t.Helper()
	dir := t.TempDir()
	stateDir := filepath.Join(dir, "state")
	if err := CreateVault(stateDir, "test-secret", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := OpenVault(stateDir, "test-secret")
	if err != nil {
		t.Fatal(err)
	}
	m := New(Config{
		Vault:       v,
		StateDir:    stateDir,
		DownloadDir: filepath.Join(dir, "downloads"),
		Name:        name,
		Region:      reg,
		Logf:        logger.Discard,
	})
	if err := m.Open(); err != nil {
		t.Fatalf("opening %s: %v", name, err)
	}
	if _, err := m.Start(); err != nil {
		t.Fatalf("starting %s: %v", name, err)
	}
	t.Cleanup(func() { m.Close() })
	return m
}

func dialNow(m *Manager, token string) (string, error) { return m.Connect(token) }

// testPNG is a real image, as avatars must be.
func testPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewGray(image.Rect(0, 0, w, h))); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func livePeer(m *Manager, id string) *peer {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.peers[id]
}

// waitEvent discards events until one matches, or the test times out.
func waitEvent(t *testing.T, m *Manager, what string, match func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		j, ok := m.NextEventTimeout(time.Second, nil)
		if !ok {
			continue
		}
		ev := make(map[string]any)
		if err := json.Unmarshal([]byte(j), &ev); err != nil {
			t.Fatalf("bad event %q: %v", j, err)
		}
		if match(ev) {
			return ev
		}
	}
	t.Fatalf("timed out waiting for %s", what)
	return nil
}

func TestE2EChat(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	logf := logger.Discard
	reg := devDERP(t, logf)

	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	aliceID, err := dialNow(bob, alice.Address())
	if err != nil {
		t.Fatalf("bob connecting to alice: %v", err)
	}

	// First contact is a request, and texts sent meanwhile are buffered.
	req := waitEvent(t, alice, "peer-request on alice", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	if req["name"] != "bob" {
		t.Errorf("alice sees requester %q, want bob", req["name"])
	}
	bobID := req["peer"].(string)
	waitEvent(t, bob, "peer-pending on bob", func(ev map[string]any) bool { return ev["type"] == "peer-pending" })
	if err := bob.SendText(aliceID, "m1", "hello from bob", ""); err != nil {
		t.Fatal(err)
	}
	if _, err := bob.SendFile(aliceID, "early", "bridge.go"); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "SendFile refused while pending", func(ev map[string]any) bool {
		return ev["type"] == "send-error" && ev["id"] == "early"
	})
	if err := alice.Accept(bobID); err != nil {
		t.Fatal(err)
	}
	added := waitEvent(t, alice, "peer-added on alice", func(ev map[string]any) bool { return ev["type"] == "peer-added" })
	if added["name"] != "bob" {
		t.Errorf("alice sees peer name %q, want bob", added["name"])
	}
	msg := waitEvent(t, alice, "bob's buffered text on alice", func(ev map[string]any) bool { return ev["type"] == "message" })
	if msg["body"] != "hello from bob" || msg["peer"] != bobID {
		t.Errorf("alice got %v", msg)
	}
	waitEvent(t, bob, "peer-accepted on bob", func(ev map[string]any) bool { return ev["type"] == "peer-accepted" })
	if err := alice.SendText(bobID, "m2", "hi bob 👋", ""); err != nil {
		t.Fatal(err)
	}
	msg = waitEvent(t, bob, "alice's text on bob", func(ev map[string]any) bool { return ev["type"] == "message" })
	if msg["body"] != "hi bob 👋" {
		t.Errorf("bob got %v", msg)
	}

	// A file big enough to need several chunks.
	blob := make([]byte, 3*chunkSize+12345)
	rand.Read(blob)
	src := filepath.Join(t.TempDir(), "photo.jpg")
	if err := os.WriteFile(src, blob, 0644); err != nil {
		t.Fatal(err)
	}
	sent, err := bob.SendFile(aliceID, "f1", src)
	if err != nil {
		t.Fatal(err)
	}
	if sent.Name != "photo.jpg" || sent.Kind != "image" || sent.Size != int64(len(blob)) {
		t.Errorf("SendFile meta = %+v", sent)
	}
	begin := waitEvent(t, alice, "file-begin on alice", func(ev map[string]any) bool { return ev["type"] == "file-begin" })
	if begin["kind"] != "image" {
		t.Errorf("received kind = %v", begin["kind"])
	}
	done := waitEvent(t, alice, "file-done on alice", func(ev map[string]any) bool { return ev["type"] == "file-done" })
	got, err := alice.cfg.Vault.ReadMedia(done["path"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, blob) {
		t.Errorf("received file differs: %d bytes vs %d sent", len(got), len(blob))
	}

	// The sender keeps a sealed copy, and resending it needs no source.
	sentDone := waitEvent(t, bob, "file-done on bob", func(ev map[string]any) bool { return ev["type"] == "file-done" })
	if sentDone["path"] != sent.Path || !bob.sealed(sent.Path) {
		t.Errorf("sender's copy at %v, SendFile said %q", sentDone["path"], sent.Path)
	}
	if got, err := bob.cfg.Vault.ReadMedia(sent.Path); err != nil || !bytes.Equal(got, blob) {
		t.Fatalf("sender's sealed copy unreadable or different (err %v)", err)
	}
	again, err := bob.SendFile(aliceID, "f2", sent.Path)
	if err != nil || again.Path != sent.Path || again.Size != int64(len(blob)) {
		t.Fatalf("resending the sealed copy = %+v, %v", again, err)
	}
	done = waitEvent(t, alice, "resent file-done", func(ev map[string]any) bool { return ev["type"] == "file-done" })
	if got, err := alice.cfg.Vault.ReadMedia(done["path"].(string)); err != nil || !bytes.Equal(got, blob) {
		t.Errorf("resent file differs (err %v)", err)
	}

	// After a reset bob is still accepted, so he reconnects directly.
	oldAddr := alice.Address()
	reset, err := alice.ResetIdentity()
	if err != nil {
		t.Fatalf("ResetIdentity: %v", err)
	}
	newAddr := reset["address"].(string)
	if newAddr == oldAddr {
		t.Fatal("ResetIdentity kept the same address")
	}
	waitEvent(t, bob, "peer-removed on bob after reset", func(ev map[string]any) bool { return ev["type"] == "peer-removed" })
	aliceID2, err := dialNow(bob, newAddr)
	if err != nil {
		t.Fatalf("bob reconnecting after reset: %v", err)
	}
	if aliceID2 == aliceID {
		t.Error("alice's identity should have changed")
	}
	waitEvent(t, alice, "peer-added (auto-accepted) on alice", func(ev map[string]any) bool { return ev["type"] == "peer-added" })
	if err := bob.SendText(aliceID2, "m3", "hello again", ""); err != nil {
		t.Fatal(err)
	}
	msg = waitEvent(t, alice, "post-reset text", func(ev map[string]any) bool { return ev["type"] == "message" })
	if msg["body"] != "hello again" {
		t.Errorf("alice got %v", msg)
	}
}

// tincanLogf drops the transport's torrential logging.
func tincanLogf(t *testing.T) logger.Logf {
	return func(format string, args ...any) {
		if strings.HasPrefix(format, "tincan:") {
			t.Logf(format, args...)
		}
	}
}

func TestPeerStatusBothSides(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)
	alice.logf = tincanLogf(t)
	bob.logf = tincanLogf(t)

	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatal(err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	if err := alice.Accept(req["peer"].(string)); err != nil {
		t.Fatal(err)
	}

	stB := waitEvent(t, bob, "peer-status on bob (outgoing side)",
		func(ev map[string]any) bool { return ev["type"] == "peer-status" })
	t.Logf("bob sees: %v", stB)
	stA := waitEvent(t, alice, "peer-status on alice (mirrored from bob)",
		func(ev map[string]any) bool { return ev["type"] == "peer-status" })
	t.Logf("alice sees: %v", stA)
	if stA["direct"] != stB["direct"] {
		t.Errorf("sides disagree: alice %v, bob %v", stA["direct"], stB["direct"])
	}

	// A rename and a new picture reach alice live.
	avatarSrc := filepath.Join(t.TempDir(), "face.png")
	avatarBytes := testPNG(t, 4, 3)
	if err := os.WriteFile(avatarSrc, avatarBytes, 0644); err != nil {
		t.Fatal(err)
	}
	if err := bob.SetProfile("bobby", "climbs rocks", "in the alps", avatarSrc, true); err != nil {
		t.Fatal(err)
	}
	prof := waitEvent(t, alice, "peer-profile on alice",
		func(ev map[string]any) bool { return ev["type"] == "peer-profile" })
	if prof["name"] != "bobby" || prof["description"] != "climbs rocks" || prof["status"] != "in the alps" {
		t.Errorf("profile = %v", prof)
	}
	got, err := alice.cfg.Vault.ReadMedia(prof["avatarPath"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(avatarBytes) {
		t.Error("avatar bytes differ after transfer")
	}

	// Restart keeps the on-disk identity, so the address is unchanged.
	before := alice.Address()
	restarted, err := alice.Restart()
	if err != nil {
		t.Fatal(err)
	}
	if after := restarted["address"]; after != before {
		t.Errorf("Restart changed the address:\n%s\n%s", before, after)
	}
}

func TestBlockUnblock(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatalf("bob connecting: %v", err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	bobID := req["peer"].(string)

	// Refuse permanently.
	if err := alice.Block(bobID); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, alice, "peer-blocked", func(ev map[string]any) bool { return ev["type"] == "peer-blocked" })
	waitEvent(t, bob, "bob's conn dropped", func(ev map[string]any) bool { return ev["type"] == "peer-removed" })
	if got := alice.ListBlocked(); len(got) != 1 || got[0].Peer != bobID || got[0].Name != "bob" {
		t.Fatalf("ListBlocked = %v", got)
	}

	// Blocked, bob's next attempt dies at the hello, indistinguishable
	// from alice being offline.
	if _, err := dialNow(bob, alice.Address()); err == nil {
		t.Fatal("blocked peer's Connect should fail")
	}

	// Undo, and the same peer can ask again.
	if err := alice.Unblock(bobID); err != nil {
		t.Fatal(err)
	}
	if got := alice.ListBlocked(); len(got) != 0 {
		t.Fatalf("ListBlocked after unblock = %v", got)
	}
	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatalf("bob reconnecting after unblock: %v", err)
	}
	req = waitEvent(t, alice, "request after unblock", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	if err := alice.Accept(req["peer"].(string)); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "accepted after unblock", func(ev map[string]any) bool { return ev["type"] == "peer-accepted" })
}

// Restoring an account brings its profile with it, and nothing of the
// replaced one lingers.
func TestRestartLoadsRestoredProfile(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	carol := newTestManager(t, "carol", reg)

	face := filepath.Join(t.TempDir(), "face.png")
	if err := os.WriteFile(face, testPNG(t, 2, 2), 0644); err != nil {
		t.Fatal(err)
	}
	if err := alice.SetProfile("Alice A", "", "", face, true); err != nil {
		t.Fatal(err)
	}
	if err := carol.SetProfile("Carol C", "bio", "", "", false); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(t.TempDir(), "carol.json")
	if err := carol.cfg.Vault.ExportAccount(backup, nil); err != nil {
		t.Fatal(err)
	}
	if err := alice.cfg.Vault.ImportAccount(backup, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := alice.Restart(); err != nil {
		t.Fatal(err)
	}
	ev := alice.selfProfileEvent()
	if ev["name"] != "Carol C" || ev["description"] != "bio" || ev["avatarPath"] != "" {
		t.Errorf("after restore: %v", ev)
	}
}

// Addresses are public and carry the key, so a hello naming an accepted
// peer's key must not be enough to speak as them.
func TestForgedHelloRejected(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	if _, err := alice.Connect(alice.Address()); err == nil {
		t.Error("dialing our own address should fail")
	}
	aliceID, err := dialNow(bob, alice.Address())
	if err != nil {
		t.Fatalf("bob connecting: %v", err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	bobID := req["peer"].(string)
	if err := alice.Accept(bobID); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cl := tailcat.NewClient(tailcat.ConnBlob(alice.Address()))
	defer cl.Close()
	for {
		if _, err := cl.Ping(ctx); err == nil {
			break
		} else if ctx.Err() != nil {
			t.Fatalf("pinging alice: %v", err)
		}
		time.Sleep(time.Second)
	}
	conn, err := cl.DialTCPPort(ctx, ChatPort)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var alicePub key.NodePublic
	if err := alicePub.UnmarshalText([]byte(aliceID)); err != nil {
		t.Fatal(err)
	}
	connKey := cl.PublicKey().String()
	forged := &wireMsg{
		T: "hello", V: protoVersion, Name: "bob", Key: bobID, ConnKey: connKey,
		Proof: key.NewNode().SealTo(alicePub, helloProof(connKey)),
	}
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	if err := writeMsgFrame(conn, forged); err != nil {
		t.Fatal(err)
	}
	if _, err := readHello(conn); err == nil {
		t.Fatal("alice answered a hello that forged bob's key")
	}
}

// The Android activity-restart path: a fresh UI asks the still-running
// transport for current state rather than starting a second time.
func TestResyncRepopulates(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatal(err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	bobID := req["peer"].(string)
	if err := alice.Accept(bobID); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, alice, "peer-added", func(ev map[string]any) bool { return ev["type"] == "peer-added" })

	// A new UI missed everything above; Resync replays it.
	alice.Resync()
	started, err := alice.Started()
	if err != nil || started["address"] != alice.Address() {
		t.Errorf("Started = %v (err %v), want the live address", started, err)
	}
	added := waitEvent(t, alice, "resynced peer-added",
		func(ev map[string]any) bool { return ev["type"] == "peer-added" })
	if added["peer"] != bobID {
		t.Errorf("resync replayed peer %v, want %v", added["peer"], bobID)
	}
}

// A requester's profile is ignored while they are still a stranger, so
// it has to reach the acceptor once they say yes.
func TestProfileReachesAcceptorAfterRequest(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	avatar := filepath.Join(t.TempDir(), "bob.png")
	bobPic := testPNG(t, 5, 5)
	if err := os.WriteFile(avatar, bobPic, 0644); err != nil {
		t.Fatal(err)
	}
	if err := bob.SetProfile("Bobby", "climbs rocks", "on the ridge", avatar, true); err != nil {
		t.Fatal(err)
	}

	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatal(err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	// Let bob's profile arrive while he is still pending; accepting at
	// once would let it land afterwards by luck and hide the bug.
	waitEvent(t, bob, "pending on bob", func(ev map[string]any) bool { return ev["type"] == "peer-pending" })
	time.Sleep(500 * time.Millisecond)
	if err := alice.Accept(req["peer"].(string)); err != nil {
		t.Fatal(err)
	}

	prof := waitEvent(t, alice, "requester's profile after accept",
		func(ev map[string]any) bool { return ev["type"] == "peer-profile" })
	if prof["name"] != "Bobby" || prof["status"] != "on the ridge" {
		t.Errorf("profile = %v", prof)
	}
	got, err := alice.cfg.Vault.ReadMedia(prof["avatarPath"].(string))
	if err != nil {
		t.Fatalf("avatar not stored: %v", err)
	}
	if !bytes.Equal(got, bobPic) {
		t.Error("avatar bytes differ")
	}

	// Clearing the picture propagates too.
	if err := bob.SetProfile("Bobby", "", "", "", true); err != nil {
		t.Fatal(err)
	}
	cleared := waitEvent(t, alice, "cleared profile", func(ev map[string]any) bool {
		return ev["type"] == "peer-profile" && ev["avatarPath"] == ""
	})
	if cleared["status"] != "" {
		t.Errorf("status not cleared: %v", cleared)
	}
}

// Two things the UI needs: the accepting side learns the peer's address
// so it can offer Reconnect, and deleting a conversation disconnects
// without blocking.
func TestProfileCarriesAddressAndDisconnect(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatal(err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	bobID := req["peer"].(string)
	if err := alice.Accept(bobID); err != nil {
		t.Fatal(err)
	}

	prof := waitEvent(t, alice, "bob's profile with his address", func(ev map[string]any) bool {
		return ev["type"] == "peer-profile" && ev["token"] != ""
	})
	if prof["token"] != bob.Address() {
		t.Errorf("learned token %v, want bob's address", prof["token"])
	}

	// Bob stays accepted, so he reconnects without asking again.
	if err := alice.Disconnect(bobID); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, alice, "peer-removed", func(ev map[string]any) bool { return ev["type"] == "peer-removed" })
	if got := alice.ListBlocked(); len(got) != 0 {
		t.Errorf("Disconnect blocked someone: %v", got)
	}
	if _, err := dialNow(bob, alice.Address()); err != nil {
		t.Fatalf("bob reconnecting after delete: %v", err)
	}
	waitEvent(t, alice, "peer-added without a new request", func(ev map[string]any) bool {
		return ev["type"] == "peer-added"
	})
}

// Two peers that dial each other at once must settle on the same one
// connection, not each close the other's and end with none.
func TestSimultaneousDialsKeepOneConnection(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)

	aliceID, err := dialNow(bob, alice.Address())
	if err != nil {
		t.Fatal(err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	bobID := req["peer"].(string)
	if err := alice.Accept(bobID); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "accepted", func(ev map[string]any) bool { return ev["type"] == "peer-accepted" })

	var wg sync.WaitGroup
	for _, d := range []struct {
		m     *Manager
		token string
	}{{alice, bob.Address()}, {bob, alice.Address()}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := dialNow(d.m, d.token); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	time.Sleep(time.Second) // the losing connections close

	a, b := livePeer(alice, bobID), livePeer(bob, aliceID)
	if a == nil || b == nil {
		t.Fatalf("a side lost the conversation: alice %v, bob %v", a != nil, b != nil)
	}
	if a.outgoing == b.outgoing {
		t.Fatalf("the sides kept different connections")
	}
	dialer := bobID
	if a.outgoing {
		dialer = aliceID
	}
	if dialer != min(aliceID, bobID) {
		t.Errorf("kept the connection dialed by %v, want the smaller key", dialer)
	}
	if err := alice.SendText(bobID, "x1", "still here", ""); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "text over the kept connection", func(ev map[string]any) bool {
		return ev["type"] == "message" && ev["body"] == "still here"
	})
}

// rawDial opens a chat-port connection to m without saying hello.
func rawDial(t *testing.T, m *Manager) (net.Conn, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cl := tailcat.NewClient(tailcat.ConnBlob(m.Address()))
	t.Cleanup(func() { cl.Close() })
	for {
		if _, err := cl.Ping(ctx); err == nil {
			break
		} else if ctx.Err() != nil {
			t.Fatalf("pinging: %v", err)
		}
		time.Sleep(time.Second)
	}
	conn, err := cl.DialTCPPort(ctx, ChatPort)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	return conn, cl.PublicKey().String()
}

// A proof is only good on the tunnel it was made for: bob's genuine
// proof for some other connection key gets nowhere, and an old
// protocol gets a readable reason.
func TestHelloBoundToTunnelAndVersioned(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)
	var alicePub key.NodePublic
	if err := alicePub.UnmarshalText([]byte(alice.selfID)); err != nil {
		t.Fatal(err)
	}
	bobKey := bob.identityKey()

	conn, _ := rawDial(t, alice)
	other := key.NewNode().Public().String()
	writeMsgFrame(conn, &wireMsg{
		T: "hello", V: protoVersion, VMin: protoMin, VMax: protoVersion, Key: bob.selfID, ConnKey: other,
		Proof: bobKey.SealTo(alicePub, helloProof(other)),
	})
	if _, err := readHello(conn); err == nil {
		t.Fatal("alice answered a proof made for another tunnel")
	}

	conn, connKey := rawDial(t, alice)
	writeMsgFrame(conn, &wireMsg{
		T: "hello", V: 1, Key: bob.selfID, ConnKey: connKey,
		Proof: bobKey.SealTo(alicePub, helloProof(connKey)),
	})
	reply, err := readHello(conn)
	if err != nil || reply.T != "error" || reply.Code != "version" || reply.Body == "" {
		t.Fatalf("v1 hello got %+v, %v; want a version error", reply, err)
	}
	waitEvent(t, alice, "peer-error", func(ev map[string]any) bool {
		return ev["type"] == "peer-error" && ev["code"] == "version" && ev["peer"] == bob.selfID
	})
}

// acceptedPair connects bob to alice and has alice accept.
func acceptedPair(t *testing.T) (alice, bob *Manager, aliceID, bobID string) {
	reg := devDERP(t, logger.Discard)
	alice = newTestManager(t, "alice", reg)
	bob = newTestManager(t, "bob", reg)
	aliceID, err := dialNow(bob, alice.Address())
	if err != nil {
		t.Fatal(err)
	}
	req := waitEvent(t, alice, "request", func(ev map[string]any) bool { return ev["type"] == "peer-request" })
	bobID = req["peer"].(string)
	if req["fp"] == "" || req["verified"] != false {
		t.Errorf("request lacks fp/verified: %v", req)
	}
	if err := alice.Accept(bobID); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "accepted", func(ev map[string]any) bool { return ev["type"] == "peer-accepted" })
	return alice, bob, aliceID, bobID
}

func TestAcksRepliesReactionsTimers(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	alice, bob, aliceID, bobID := acceptedPair(t)

	if err := bob.SendText(aliceID, "m1", "first", ""); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "delivered m1", func(ev map[string]any) bool { return ev["type"] == "delivered" && ev["id"] == "m1" })
	if err := alice.SendText(bobID, "m2", "answer", "m1"); err != nil {
		t.Fatal(err)
	}
	msg := waitEvent(t, bob, "reply", func(ev map[string]any) bool { return ev["type"] == "message" && ev["id"] == "m2" })
	if msg["reply"] != "m1" {
		t.Errorf("reply lost: %v", msg)
	}
	waitEvent(t, alice, "delivered m2", func(ev map[string]any) bool { return ev["type"] == "delivered" && ev["id"] == "m2" })

	if err := bob.SendReaction(aliceID, "r1", "m2", "👍"); err != nil {
		t.Fatal(err)
	}
	re := waitEvent(t, alice, "react", func(ev map[string]any) bool { return ev["type"] == "react" })
	if re["ref"] != "m2" || re["body"] != "👍" || re["peer"] != bobID {
		t.Errorf("react = %v", re)
	}
	waitEvent(t, bob, "delivered r1", func(ev map[string]any) bool { return ev["type"] == "delivered" && ev["id"] == "r1" })

	if err := alice.SendTimer(bobID, "t1", 3600); err != nil {
		t.Fatal(err)
	}
	tm := waitEvent(t, bob, "peer-timer", func(ev map[string]any) bool { return ev["type"] == "peer-timer" })
	if tm["seconds"] != float64(3600) {
		t.Errorf("timer = %v", tm)
	}

	if err := alice.SetVerified(bobID, true); err != nil {
		t.Fatal(err)
	}
	alice.Resync()
	added := waitEvent(t, alice, "resynced peer", func(ev map[string]any) bool { return ev["type"] == "peer-added" })
	if added["verified"] != true || added["fp"] != fingerprint(aliceID, bobID) {
		t.Errorf("peer-added = %v", added)
	}
}

// A transfer cut off midway resumes from the kept part.
func TestFileResumes(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	alice, bob, aliceID, bobID := acceptedPair(t)

	blob := make([]byte, 3*chunkSize+777)
	rand.Read(blob)
	src := filepath.Join(t.TempDir(), "clip.mp4")
	if err := os.WriteFile(src, blob, 0644); err != nil {
		t.Fatal(err)
	}

	// What an earlier, interrupted attempt left on alice's side.
	part := alice.partPath(bobID + "\x00" + "f1")
	os.MkdirAll(filepath.Dir(part), 0700)
	f, err := os.OpenFile(part, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		t.Fatal(err)
	}
	w, _, err := alice.cfg.Vault.ResumePart(f)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(blob[:2*chunkSize]); err != nil {
		t.Fatal(err)
	}
	f.Close()

	if _, err := bob.SendFile(aliceID, "f1", src); err != nil {
		t.Fatal(err)
	}
	begin := waitEvent(t, alice, "file-begin", func(ev map[string]any) bool { return ev["type"] == "file-begin" })
	if begin["have"] != float64(2*chunkSize) {
		t.Errorf("resumed from %v, want %d", begin["have"], 2*chunkSize)
	}
	done := waitEvent(t, alice, "file-done", func(ev map[string]any) bool { return ev["type"] == "file-done" })
	got, err := alice.cfg.Vault.ReadMedia(done["path"].(string))
	if err != nil || !bytes.Equal(got, blob) {
		t.Fatalf("resumed file differs (err %v, %d bytes)", err, len(got))
	}
	waitEvent(t, bob, "file delivered", func(ev map[string]any) bool { return ev["type"] == "delivered" && ev["id"] == "f1" })
	if _, err := os.Stat(part); !os.IsNotExist(err) {
		t.Errorf("part left behind: %v", err)
	}
	if _, err := bob.SendFile(aliceID, "an-id-way-too-long", src); err == nil {
		t.Error("an id longer than a blob frame holds was accepted")
	}
}
