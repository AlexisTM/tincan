package bridge

import (
	"context"
	"encoding/json"
	"errors"
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
	f := probeFunc(func(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
		if relayed.Load() {
			return &ipnstate.PingResult{DERPRegionCode: "D", LatencySeconds: 0.05}, nil
		}
		return &ipnstate.PingResult{Endpoint: "127.0.0.1:41641", LatencySeconds: 0.001}, nil
	})
	m.probeFn.Store(&f)
}

// failPath makes every probe of m fail, so it measures nothing.
func failPath(m *Manager) {
	f := probeFunc(func(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
		return nil, errors.New("no path")
	})
	m.probeFn.Store(&f)
}

// within fails unless ch yields before the e2e timeout.
func within[T any](t *testing.T, ch <-chan T, what string) T {
	t.Helper()
	select {
	case v := <-ch:
		return v
	case <-time.After(90 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
	var zero T
	return zero
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
	d := within(t, done, "dial once direct")
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
	// A stranger is held without a word to the UI.
	noneFor(t, alice, 3*time.Second, "request or status while relayed", func(ev map[string]any) bool {
		return ev["type"] == "peer-request" || ev["type"] == "peer-status"
	})
	select {
	case err := <-done:
		t.Fatalf("dial settled while the acceptor held it: %v", err)
	default:
	}

	relayed.Store(false)
	if err := within(t, done, "dial once direct"); err != nil {
		t.Fatal(err)
	}
	waitEvent(t, alice, "request once direct", isEvent("peer-request"))
}

func TestSetDirectOnlyDropsRelayedConversations(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping e2e in -short mode")
	}
	reg := devDERP(t, logger.Discard)
	alice := newTestManager(t, "alice", reg)
	bob := newTestManager(t, "bob", reg)
	carol := newTestManager(t, "carol", reg)
	aliceID, _ := acceptDial(t, bob, alice)
	carolID, _ := acceptDial(t, bob, carol)

	// statusLoop learns nothing from here on, so only SetDirectOnly drops.
	failPath(bob)
	relayed, direct := livePeer(bob, aliceID), livePeer(bob, carolID)
	for relayed.pingBusy.Load() || direct.pingBusy.Load() {
		time.Sleep(10 * time.Millisecond)
	}
	relayed.direct.Store(false)
	relayed.measured.Store(true)
	direct.direct.Store(true)
	direct.measured.Store(true)

	bob.SetDirectOnly(true)
	if livePeer(bob, aliceID) != nil {
		t.Error("kept a conversation measured relayed")
	}
	if livePeer(bob, carolID) != direct {
		t.Error("dropped a direct conversation")
	}
	waitEvent(t, bob, "peer-removed", func(ev map[string]any) bool {
		return ev["type"] == "peer-removed" && ev["peer"] == aliceID
	})
	bob.SetDirectOnly(false)
	if _, err := bob.Connect(alice.Address()); err != nil {
		t.Fatalf("redial with direct-only off: %v", err)
	}
}
