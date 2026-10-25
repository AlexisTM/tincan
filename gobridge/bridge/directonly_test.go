package bridge

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/logger"
)

// fakePath makes m see a relayed path while relayed holds, a direct one
// otherwise; the dev relay can't produce a real relayed path.
func fakePath(m *Manager, relayed *atomic.Bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.probeFn = func(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
		if relayed.Load() {
			return &ipnstate.PingResult{DERPRegionCode: "D", LatencySeconds: 0.05}, nil
		}
		return &ipnstate.PingResult{Endpoint: "127.0.0.1:41641", LatencySeconds: 0.001}, nil
	}
}

func decodeEvent(t *testing.T, j string) map[string]any {
	t.Helper()
	ev := make(map[string]any)
	if err := json.Unmarshal([]byte(j), &ev); err != nil {
		t.Fatalf("bad event %q: %v", j, err)
	}
	return ev
}

func isEvent(typ string) func(map[string]any) bool {
	return func(ev map[string]any) bool { return ev["type"] == typ }
}

// noneFor fails if m emits a matching event within d.
func noneFor(t *testing.T, m *Manager, d time.Duration, what string, match func(map[string]any) bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		j, ok := m.NextEventTimeout(time.Until(deadline), nil)
		if !ok {
			return
		}
		if ev := decodeEvent(t, j); match(ev) {
			t.Fatalf("%s: got %v", what, ev)
		}
	}
}

func TestDirectOnlyDialWaitsForDirectPath(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)
	var relayed atomic.Bool
	relayed.Store(true)
	fakePath(bob, &relayed)
	bob.SetDirectOnly(true)

	bob.directWait = 3 * time.Second
	if _, err := bob.Connect(alice.Address()); err == nil || err.Error() != errNoDirect.Error() {
		t.Fatalf("relayed dial = %v, want %q", err, errNoDirect)
	}
	waitEvent(t, bob, "connect-error", func(ev map[string]any) bool {
		return ev["type"] == "connect-error" && ev["error"] == errNoDirect.Error()
	})

	bob.directWait = time.Minute
	type dialed struct {
		id  string
		err error
	}
	done := make(chan dialed, 1)
	go func() {
		id, err := bob.Connect(alice.Address())
		done <- dialed{id, err}
	}()
	held := waitEvent(t, bob, "held status", isEvent("peer-status"))
	if held["held"] != true || held["peer"] != alice.selfID {
		t.Errorf("held status = %v", held)
	}
	// Not a byte of chat while the path is relayed: alice never sees a hello.
	noneFor(t, alice, 3*time.Second, "alice heard bob over the relay", isEvent("peer-request"))
	if ps := alice.snapshotPeers(true); len(ps) != 0 {
		t.Fatalf("alice holds %d connections before the path is direct", len(ps))
	}
	select {
	case d := <-done:
		t.Fatalf("dial settled while relayed: %+v", d)
	default:
	}

	relayed.Store(false)
	d := <-done
	if d.err != nil || d.id != alice.selfID {
		t.Fatalf("dial once direct = %+v", d)
	}
	req := waitEvent(t, alice, "request", isEvent("peer-request"))
	if err := alice.Accept(req["peer"].(string)); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, bob, "accepted", isEvent("peer-accepted"))

	// Falling back to the relay ends the conversation.
	relayed.Store(true)
	bob.SetActivePeer(alice.selfID)
	waitEvent(t, bob, "peer-removed once relayed", isEvent("peer-removed"))
	if err := bob.SendText(alice.selfID, "m1", "over the relay?", ""); err == nil {
		t.Error("sent a text with the path relayed")
	}
}

func TestDirectOnlyAcceptorHolds(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)
	var relayed atomic.Bool
	relayed.Store(true)
	fakePath(bob, &relayed)
	alice.SetDirectOnly(true)

	done := make(chan error, 1)
	go func() {
		_, err := bob.Connect(alice.Address())
		done <- err
	}()
	held := waitEvent(t, alice, "held status on the acceptor", isEvent("peer-status"))
	if held["held"] != true || held["peer"] != bob.selfID {
		t.Errorf("held status = %v", held)
	}
	noneFor(t, alice, 3*time.Second, "request while relayed", isEvent("peer-request"))
	select {
	case err := <-done:
		t.Fatalf("dial settled while the acceptor held it: %v", err)
	default:
	}

	relayed.Store(false)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	waitEvent(t, alice, "request once direct", isEvent("peer-request"))
}

func TestSetDirectOnlyDropsRelayedConversations(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	alice, bob, aliceID, _ := acceptedPair(t)
	var relayed atomic.Bool
	relayed.Store(true)
	fakePath(bob, &relayed)
	livePeer(bob, aliceID).direct.Store(false)
	bob.SetDirectOnly(true)
	waitEvent(t, bob, "peer-removed", isEvent("peer-removed"))
	bob.SetDirectOnly(false)
	if _, err := bob.Connect(alice.Address()); err != nil {
		t.Fatalf("redial with direct-only off: %v", err)
	}
}

func TestCancelTransfer(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	alice, bob, aliceID, bobID := acceptedPair(t)

	// The sender cancels; the receiver drops what it kept.
	part := alice.partPath(recvKey(&peer{id: bobID}, "f1"))
	os.MkdirAll(filepath.Dir(part), 0700)
	if err := os.WriteFile(part, []byte("half a file"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := bob.CancelTransfer(aliceID, "f1"); err != nil {
		t.Fatal(err)
	}
	ev := waitEvent(t, alice, "cancel on the receiver", isEvent("transfer-cancelled"))
	if ev["peer"] != bobID || ev["id"] != "f1" {
		t.Errorf("transfer-cancelled = %v", ev)
	}
	if _, err := os.Stat(part); !os.IsNotExist(err) {
		t.Errorf("partial kept after cancel: %v", err)
	}

	// The receiver cancels; the sender hears of it.
	if err := alice.CancelTransfer(bobID, "f2"); err != nil {
		t.Fatal(err)
	}
	ev = waitEvent(t, bob, "cancel on the sender", isEvent("transfer-cancelled"))
	if ev["peer"] != aliceID || ev["id"] != "f2" {
		t.Errorf("transfer-cancelled = %v", ev)
	}

	// A send cancelled as it starts never completes, but keeps its copy.
	blob := make([]byte, 8*chunkSize)
	rand.Read(blob)
	src := filepath.Join(t.TempDir(), "big.bin")
	if err := os.WriteFile(src, blob, 0644); err != nil {
		t.Fatal(err)
	}
	sent, err := bob.SendFile(aliceID, "f3", src)
	if err != nil {
		t.Fatal(err)
	}
	if err := bob.CancelTransfer(aliceID, "f3"); err != nil {
		t.Fatal(err)
	}
	noneFor(t, alice, 3*time.Second, "cancelled file arrived", func(ev map[string]any) bool {
		return ev["type"] == "file-done" && ev["id"] == "f3"
	})
	if _, err := os.Stat(alice.partPath(recvKey(&peer{id: bobID}, "f3"))); !os.IsNotExist(err) {
		t.Errorf("receiver kept a cancelled partial: %v", err)
	}
	if got, err := bob.cfg.Vault.ReadMedia(sent.Path); err != nil || len(got) != len(blob) {
		t.Errorf("sender's sealed copy after cancel: %d bytes, %v", len(got), err)
	}
}
