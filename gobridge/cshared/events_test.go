package main

import (
	"testing"
	"time"
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

func TestCarriedEventGoesToNewPump(t *testing.T) {
	cur := attachEvents()
	pumpMu.Lock()
	carried = append(carried, `{"type":"message"}`)
	pumpMu.Unlock()
	if ev := nextEvent(cur, time.Millisecond); ev != `{"type":"message"}` {
		t.Fatalf("got %q", ev)
	}
}
