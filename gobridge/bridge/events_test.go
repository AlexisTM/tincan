package bridge

import (
	"encoding/json"
	"slices"
	"testing"
	"time"
)

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

// drain collects event types in order until nothing comes for wait.
func drain(m *Manager, wait time.Duration) []string {
	var got []string
	for {
		j, ok := m.NextEventTimeout(wait, nil)
		if !ok {
			return got
		}
		var ev map[string]any
		json.Unmarshal([]byte(j), &ev)
		typ, _ := ev["type"].(string)
		if held, ok := ev["held"].(bool); ok {
			typ += map[bool]string{true: "+held", false: "-held"}[held]
		}
		got = append(got, typ)
	}
}

func expectEvents(t *testing.T, got []string, want ...string) {
	t.Helper()
	if !slices.Equal(got, want) {
		t.Fatalf("events %v, want %v", got, want)
	}
}

func TestSupersededStatusNeverFollows(t *testing.T) {
	m := New(Config{})
	m.emit(map[string]any{"type": "peer-status", "peer": "p", "direct": true})
	m.emit(map[string]any{"type": "peer-status", "peer": "p", "direct": false})
	m.emit(map[string]any{"type": "peer-removed", "peer": "p"})
	expectEvents(t, drain(m, 2*coalesceEvery), "peer-status", "peer-removed")
}

func TestReleasedHoldSurvivesRemoval(t *testing.T) {
	m := New(Config{})
	m.emit(map[string]any{"type": "peer-status", "peer": "p", "held": true})
	m.emit(map[string]any{"type": "peer-status", "peer": "p", "held": false})
	m.emit(map[string]any{"type": "peer-removed", "peer": "p"})
	expectEvents(t, drain(m, 2*coalesceEvery), "peer-status+held", "peer-status-held", "peer-removed")
}

func TestParkedAcceptLandsAfterAdded(t *testing.T) {
	m := New(Config{})
	m.emit(map[string]any{"type": "peer-pending", "peer": "p"})
	m.emit(map[string]any{"type": "peer-accepted", "peer": "p"})
	m.emit(map[string]any{"type": "peer-added", "peer": "p"})
	expectEvents(t, drain(m, 2*coalesceEvery), "peer-pending", "peer-added", "peer-accepted")
}

func TestRequestGoneCancelsQueuedRequest(t *testing.T) {
	m := New(Config{})
	m.emit(map[string]any{"type": "peer-request", "peer": "p"})
	m.emit(map[string]any{"type": "peer-request-gone", "peer": "p"})
	expectEvents(t, drain(m, 2*coalesceEvery))
}

func TestRequestGoneFollowsTakenRequest(t *testing.T) {
	m := New(Config{})
	m.emit(map[string]any{"type": "peer-request", "peer": "p"})
	expectEvents(t, drain(m, 100*time.Millisecond), "peer-request")
	m.emit(map[string]any{"type": "peer-request-gone", "peer": "p"})
	expectEvents(t, drain(m, 100*time.Millisecond), "peer-request-gone")
}

func TestCapDropsOnlyLossyEvents(t *testing.T) {
	m := New(Config{})
	for range maxLossyQueued {
		m.emit(map[string]any{"type": "message", "peer": "p"})
	}
	m.emit(map[string]any{"type": "file-progress", "peer": "p"})
	m.emit(map[string]any{"type": "peer-error", "peer": "q"})
	m.emit(map[string]any{"type": "message", "peer": "p"})
	got := drain(m, 100*time.Millisecond)
	if len(got) != maxLossyQueued+1 || slices.Contains(got, "file-progress") || slices.Contains(got, "peer-error") {
		t.Fatalf("%d events, lossy kept: %v", len(got),
			slices.Contains(got, "file-progress") || slices.Contains(got, "peer-error"))
	}
}

func TestRequeuedOrderSurvivesTakeRefusal(t *testing.T) {
	m := New(Config{})
	m.emit(map[string]any{"type": "message", "peer": "p", "id": "1"})
	m.emit(map[string]any{"type": "message", "peer": "p", "id": "2"})
	if _, ok := m.NextEventIf(50*time.Millisecond, nil, func() bool { return false }); ok {
		t.Fatal("refused take still handed an event over")
	}
	var ids []string
	for range 2 {
		j, ok := m.NextEventTimeout(100*time.Millisecond, nil)
		if !ok {
			t.Fatal("event lost after a refused take")
		}
		var ev map[string]any
		json.Unmarshal([]byte(j), &ev)
		ids = append(ids, ev["id"].(string))
	}
	expectEvents(t, ids, "1", "2")
}
