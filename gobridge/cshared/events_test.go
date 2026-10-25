package main

import (
	"testing"
	"time"

	"tincan.dev/gobridge/bridge"
)

func TestNewerPumpRetiresOlder(t *testing.T) {
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

func TestQueuedEventGoesToNewPump(t *testing.T) {
	m := bridge.New(bridge.Config{})
	mu.Lock()
	mgr = m
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		mgr = nil
		mu.Unlock()
	})
	old := attachEvents()
	m.Requeue(`{"type":"message"}`)
	cur := attachEvents()
	if ev := nextEvent(old, time.Millisecond); ev != staleEvent {
		t.Fatalf("old pump got %q", ev)
	}
	if ev := nextEvent(cur, time.Millisecond); ev != `{"type":"message"}` {
		t.Fatalf("got %q", ev)
	}
}
