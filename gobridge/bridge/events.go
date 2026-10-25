package bridge

import (
	"encoding/json"
	"sync"
	"time"
)

// Events reach the host through one ordered queue. Anything carrying
// user data (messages, files, acks) is never dropped; a peer can only
// flood it with what we already accepted from them. Chatter a stranger
// can trigger at will (status, pending, requests, profiles) is
// coalesced per peer to one per coalesceEvery, latest wins, and status
// and progress are dropped outright when the host falls behind.

const (
	maxLossyQueued = 1024
	coalesceEvery  = time.Second
)

type eventQueue struct {
	mu   sync.Mutex
	q    []string
	wake chan struct{}

	last map[string]time.Time
	held map[string]map[string]any // coalesced, waiting for their slot
}

func newEventQueue() *eventQueue {
	return &eventQueue{
		wake: make(chan struct{}, 1),
		last: make(map[string]time.Time),
		held: make(map[string]map[string]any),
	}
}

func lossy(typ string) bool { return typ == "peer-status" || typ == "file-progress" }

// coalesceKey groups events where only the latest matters.
func coalesceKey(typ string, ev map[string]any) string {
	peer, _ := ev["peer"].(string)
	switch typ {
	case "peer-status", "peer-request", "peer-profile":
		return typ + "|" + peer
	case "peer-pending", "peer-accepted":
		return "remote|" + peer
	}
	return ""
}

func (m *Manager) emit(ev map[string]any) {
	q := m.ev
	typ, _ := ev["type"].(string)
	peer, _ := ev["peer"].(string)
	switch typ {
	case "peer-added", "peer-removed", "peer-request-gone", "peer-blocked":
		// Supersedes whatever was held for this peer, so a stale request
		// can't land after its answer.
		q.forget(peer)
	}
	if key := coalesceKey(typ, ev); key != "" && q.hold(key, ev, m.logf) {
		return
	}
	q.push(ev, m.logf)
}

func (q *eventQueue) push(ev map[string]any, logf func(string, ...any)) {
	j, err := json.Marshal(ev)
	if err != nil {
		return
	}
	q.mu.Lock()
	if typ, _ := ev["type"].(string); lossy(typ) && len(q.q) >= maxLossyQueued {
		q.mu.Unlock()
		logf("tincan: event queue backed up, dropping %s", typ)
		return
	}
	q.q = append(q.q, string(j))
	q.mu.Unlock()
	q.signal()
}

func (q *eventQueue) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

// hold reports whether ev was parked to go out later.
func (q *eventQueue) hold(key string, ev map[string]any, logf func(string, ...any)) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	now := time.Now()
	wait := coalesceEvery - now.Sub(q.last[key])
	if wait <= 0 {
		q.last[key] = now
		return false
	}
	_, timerSet := q.held[key]
	q.held[key] = ev
	if !timerSet {
		time.AfterFunc(wait, func() {
			q.mu.Lock()
			ev, ok := q.held[key]
			delete(q.held, key)
			if ok {
				q.last[key] = time.Now()
			}
			q.mu.Unlock()
			if ok {
				q.push(ev, logf)
			}
		})
	}
	return true
}

func (q *eventQueue) forget(peer string) {
	if peer == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	delete(q.held, "peer-request|"+peer)
	delete(q.held, "remote|"+peer)
	delete(q.held, "peer-status|"+peer) // a parked "held" would outlive the connection
}

func (q *eventQueue) pop() (string, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.q) == 0 {
		return "", false
	}
	ev := q.q[0]
	q.q[0] = ""
	q.q = q.q[1:]
	return ev, true
}

// NextEventTimeout yields one JSON object per event, each with a
// "type", waiting up to d or until cancel closes. FFI callers poll
// rather than block forever: a thread parked in native code wedges the
// host VM's shutdown.
func (m *Manager) NextEventTimeout(d time.Duration, cancel <-chan struct{}) (ev string, ok bool) {
	t := time.NewTimer(d)
	defer t.Stop()
	for {
		if ev, ok := m.ev.pop(); ok {
			return ev, true
		}
		select {
		case <-m.ev.wake:
		case <-t.C:
			return "", false
		case <-cancel:
			return "", false
		}
	}
}

// Requeue puts back an event taken by a consumer that turned out to be
// stale, ahead of everything else.
func (m *Manager) Requeue(ev string) {
	q := m.ev
	q.mu.Lock()
	q.q = append([]string{ev}, q.q...)
	q.mu.Unlock()
	q.signal()
}
