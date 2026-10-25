package main

import (
	"strings"
	"testing"
	"time"

	"tincan.dev/gobridge/bridge"
)

func resetPumps(t *testing.T) {
	t.Cleanup(func() {
		pumpMu.Lock()
		pumpGen = 0
		pumpCut = make(chan struct{})
		pumpMu.Unlock()
	})
}

func TestNewerPumpRetiresOlder(t *testing.T) {
	resetPumps(t)
	old := attachEvents()
	done := make(chan string)
	go func() { done <- nextEvent(old, 10*time.Second) }()
	time.Sleep(50 * time.Millisecond)
	cur := attachEvents()
	select {
	case ev := <-done:
		if ev != "" {
			t.Fatalf("waiting pump got %q, want a timeout-style wake", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("old pump kept waiting after a newer one attached")
	}
	if ev := nextEvent(old, time.Millisecond); ev != staleEvent {
		t.Fatalf("old pump got %q, want %q", ev, staleEvent)
	}
	if ev := nextEvent(cur, time.Millisecond); ev != "" {
		t.Fatalf("current pump got %q, want a plain timeout", ev)
	}
}

func TestRetiredPumpLeavesEventForNewer(t *testing.T) {
	resetPumps(t)
	dir := t.TempDir()
	if err := bridge.CreateVault(dir, "pw", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := bridge.OpenVault(dir, "pw")
	if err != nil {
		t.Fatal(err)
	}
	m := bridge.New(bridge.Config{Vault: v, StateDir: dir})
	mu.Lock()
	mgr = m
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		mgr = nil
		mu.Unlock()
		m.Close()
	})

	old := attachEvents()
	done := make(chan string)
	go func() { done <- nextEvent(old, 10*time.Second) }()
	time.Sleep(50 * time.Millisecond)
	// Retire it without cutting it loose, so it wakes for the event.
	pumpMu.Lock()
	pumpGen++
	cur := pumpGen
	pumpMu.Unlock()
	m.Block("x")
	select {
	case ev := <-done:
		if ev != "" {
			t.Fatalf("retired pump took %q", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("retired pump kept waiting")
	}
	if ev := nextEvent(old, time.Millisecond); ev != staleEvent {
		t.Fatalf("old pump got %q, want %q", ev, staleEvent)
	}
	if ev := nextEvent(cur, time.Second); !strings.Contains(ev, `"peer-blocked"`) {
		t.Fatalf("current pump got %q, want the peer-blocked event", ev)
	}
}

func TestStoppedTransportDrainsBeforeMarker(t *testing.T) {
	resetPumps(t)
	dir := t.TempDir()
	if err := bridge.CreateVault(dir, "pw", "password"); err != nil {
		t.Fatal(err)
	}
	v, err := bridge.OpenVault(dir, "pw")
	if err != nil {
		t.Fatal(err)
	}
	m := bridge.New(bridge.Config{Vault: v, StateDir: dir})
	mu.Lock()
	mgr = m
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		mgr, draining = nil, nil
		mu.Unlock()
	})

	gen := attachEvents()
	m.Block("x")
	if err := stopTransport(); err != nil {
		t.Fatal(err)
	}
	if ev := nextEvent(gen, time.Second); !strings.Contains(ev, `"peer-blocked"`) {
		t.Fatalf("got %q, want the event queued before the stop", ev)
	}
	if ev := nextEvent(gen, time.Second); !strings.Contains(ev, `"transport-stopped"`) {
		t.Fatalf("got %q, want the stop marker", ev)
	}
	if err := stopTransport(); err == nil {
		t.Error("stopping twice should say the bridge is not started")
	}
}
