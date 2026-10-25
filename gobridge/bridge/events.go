package bridge

import (
	"encoding/json"
	"sync"
	"time"
)

// One FIFO to the host; per-peer chatter is coalesced, only lossy() types drop.

const (
	maxLossyQueued = 1024
	coalesceEvery  = time.Second
	maxLastKeys    = 256
)

type queuedEvent struct{ key, j string } // j == "" once cancelled

type parkedEvent struct {
	ev map[string]any
	t  *time.Timer
}

type eventQueue struct {
	mu   sync.Mutex
	q    []queuedEvent
	head int            // events popped so far
	at   map[string]int // key -> position of its event while still queued
	wake chan struct{}

	last map[string]time.Time
	held map[string]*parkedEvent // waiting out coalesceEvery
}

func newEventQueue() *eventQueue {
	return &eventQueue{
		wake: make(chan struct{}, 1),
		at:   make(map[string]int),
		last: make(map[string]time.Time),
		held: make(map[string]*parkedEvent),
	}
}

// lossy types are dropped when the host falls behind; strangers can
// trigger the errors at will.
func lossy(typ string) bool {
	switch typ {
	case "file-progress", "peer-error", "connect-error", "transport-error":
		return true
	}
	return false
}

// coalesceKey groups events where only the latest matters.
func coalesceKey(typ, peer string) string {
	switch typ {
	case "peer-status", "peer-request", "peer-profile", "peer-request-gone":
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
	key := coalesceKey(typ, peer)
	q.mu.Lock()
	defer q.mu.Unlock()
	var after []map[string]any
	switch typ {
	case "peer-request-gone":
		// Never seen, so it needn't be seen to go.
		cancelled := q.unqueue("peer-request|" + peer)
		q.supersede(typ, peer, m.logf)
		if !cancelled {
			q.enqueue(key, ev, m.logf)
		}
		return
	case "peer-added", "peer-removed", "peer-blocked":
		after = q.supersede(typ, peer, m.logf)
	}
	if key == "" || !q.hold(key, ev, m.logf) {
		q.enqueue(key, ev, m.logf)
	}
	for _, ev := range after {
		typ, _ := ev["type"].(string)
		k := coalesceKey(typ, peer)
		q.last[k] = time.Now()
		q.enqueue(k, ev, m.logf)
	}
}

// supersede settles what is parked for peer ahead of typ, and returns
// what has to follow it; q.mu held.
func (q *eventQueue) supersede(typ, peer string, logf func(string, ...any)) (after []map[string]any) {
	if peer == "" {
		return nil
	}
	for _, kind := range []string{"peer-request", "peer-status", "remote", "peer-profile"} {
		key := kind + "|" + peer
		delete(q.at, key) // later ones mustn't jump ahead of typ
		p := q.held[key]
		if p == nil {
			continue
		}
		p.t.Stop()
		delete(q.held, key)
		flush := false
		switch {
		case kind == "peer-request":
		case kind == "peer-status":
			// A parked held:true would outlive the connection; held:false ends one.
			held, ok := p.ev["held"].(bool)
			flush = ok && !held && typ != "peer-added"
		case typ == "peer-blocked":
		case typ == "peer-added":
			// Newer than the snapshot peer-added was built from.
			after = append(after, p.ev)
		default:
			flush = true
		}
		if flush {
			q.last[key] = time.Now()
			q.enqueue(key, p.ev, logf)
		}
	}
	return after
}

// hold reports whether ev was parked to go out later; q.mu held.
func (q *eventQueue) hold(key string, ev map[string]any, logf func(string, ...any)) bool {
	if p := q.held[key]; p != nil {
		p.ev = ev
		return true
	}
	now := time.Now()
	wait := coalesceEvery - now.Sub(q.last[key])
	if wait <= 0 {
		q.pruneLast(now)
		q.last[key] = now
		return false
	}
	p := &parkedEvent{ev: ev}
	q.held[key] = p
	p.t = time.AfterFunc(wait, func() {
		q.mu.Lock()
		defer q.mu.Unlock()
		if q.held[key] != p {
			return
		}
		delete(q.held, key)
		q.last[key] = time.Now()
		q.enqueue(key, p.ev, logf)
	})
	return true
}

// pruneLast forgets keys past their window, which no longer hold anything.
func (q *eventQueue) pruneLast(now time.Time) {
	if len(q.last) < maxLastKeys {
		return
	}
	for k, t := range q.last {
		if now.Sub(t) >= coalesceEvery {
			delete(q.last, k)
		}
	}
}

// enqueue appends ev, or overwrites its key's event still in the
// queue; q.mu held.
func (q *eventQueue) enqueue(key string, ev map[string]any, logf func(string, ...any)) {
	typ, _ := ev["type"].(string)
	j, err := json.Marshal(ev)
	if err != nil {
		logf("tincan: dropping %s event: %v", typ, err)
		return
	}
	if i, ok := q.at[key]; ok && key != "" {
		q.q[i-q.head].j = string(j)
		return
	}
	if lossy(typ) && len(q.q) >= maxLossyQueued {
		logf("tincan: event queue backed up, dropping %s", typ)
		return
	}
	if key != "" {
		q.at[key] = q.head + len(q.q)
	}
	q.q = append(q.q, queuedEvent{key, string(j)})
	q.signal()
}

// unqueue cancels key's event if the host hasn't taken it; q.mu held.
func (q *eventQueue) unqueue(key string) bool {
	i, ok := q.at[key]
	if !ok {
		return false
	}
	delete(q.at, key)
	q.q[i-q.head] = queuedEvent{}
	return true
}

func (q *eventQueue) signal() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

// pop takes the next event unless take, run under the lock, refuses.
func (q *eventQueue) pop(take func() bool) (ev string, ok, refused bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for len(q.q) > 0 && q.q[0].j == "" {
		q.shift()
	}
	if len(q.q) == 0 {
		return "", false, false
	}
	if take != nil && !take() {
		q.signal() // the wake was meant for whoever may take it
		return "", false, true
	}
	ev = q.q[0].j
	q.shift()
	return ev, true, false
}

func (q *eventQueue) shift() {
	if k := q.q[0].key; k != "" && q.at[k] == q.head {
		delete(q.at, k)
	}
	q.q[0] = queuedEvent{}
	q.q = q.q[1:]
	q.head++
	if len(q.q) == 0 {
		q.q = nil
	}
}

// NextEventTimeout yields one JSON object per event, each with a
// "type", waiting up to d or until cancel closes. FFI callers poll
// rather than block forever: a thread parked in native code wedges the
// host VM's shutdown.
func (m *Manager) NextEventTimeout(d time.Duration, cancel <-chan struct{}) (ev string, ok bool) {
	return m.NextEventIf(d, cancel, nil)
}

// NextEventIf is NextEventTimeout for a consumer that may go stale:
// take runs under the queue lock before an event is handed over, and
// false leaves it queued.
func (m *Manager) NextEventIf(d time.Duration, cancel <-chan struct{}, take func() bool) (ev string, ok bool) {
	t := time.NewTimer(d)
	defer t.Stop()
	for {
		ev, ok, refused := m.ev.pop(take)
		if ok || refused {
			return ev, ok
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
