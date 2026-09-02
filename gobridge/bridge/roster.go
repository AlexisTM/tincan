package bridge

import (
	"errors"
	"fmt"
	"maps"
	"os"
	"sort"
)

// The roster gates who may chat with us, persisted in peers.json. A
// first-time caller is held as a pending request until accepted or
// blocked; peers we dial are accepted implicitly. Blocked peers are
// closed right after their hello with no reply, so they can't tell
// blocked from unreachable.

const rosterFile = "peers.json"

type rosterData struct {
	Accepted map[string]string `json:"accepted"` // peer key -> last seen name
	Blocked  map[string]string `json:"blocked"`
}

func (m *Manager) loadRoster() error {
	var r rosterData
	err := m.loadJSON(rosterFile, &r)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	m.accepted = r.Accepted
	m.blocked = r.Blocked
	return nil
}

type rosterSnapshot struct {
	rosterData
	seq uint64
}

// rosterLocked copies the roster for saveRoster; m.mu held.
func (m *Manager) rosterLocked() rosterSnapshot {
	m.rosterSeq++
	return rosterSnapshot{rosterData{maps.Clone(m.accepted), maps.Clone(m.blocked)}, m.rosterSeq}
}

// saveRoster persists a snapshot outside m.mu, unless a newer one
// already landed.
func (m *Manager) saveRoster(r rosterSnapshot) {
	m.saveMu.Lock()
	defer m.saveMu.Unlock()
	if r.seq <= m.rosterSaved {
		return
	}
	m.rosterSaved = r.seq
	if err := m.saveJSON(rosterFile, r.rosterData); err != nil {
		m.logf("tincan: saving roster: %v", err)
	}
}

// Accept turns a pending request into a conversation and replays
// whatever they sent while waiting.
func (m *Manager) Accept(peerID string) error {
	m.mu.Lock()
	p := m.pending[peerID]
	if p == nil {
		m.mu.Unlock()
		return fmt.Errorf("no pending request from %v", peerID)
	}
	delete(m.pending, peerID)
	drop := m.installPeerLocked(p, false)
	live := m.peers[peerID]
	mapSet(&m.accepted, peerID, p.name)
	roster := m.rosterLocked()
	texts := p.pendingTexts
	p.pendingTexts = nil
	profile := p.pendingProfile
	p.pendingProfile = nil
	m.mu.Unlock()

	m.saveRoster(roster)
	drop.close()
	m.emit(m.peerAddedEvent(live))
	if profile != nil {
		m.applyPeerProfile(live, profile)
	}
	for _, t := range texts {
		m.emit(messageEvent(p, t))
	}
	if live != p {
		return nil // a connection of their own dialing won the tie-break
	}
	if err := p.writeMsg(&wireMsg{T: "accepted"}); err != nil {
		return err
	}
	go p.writeMsg(m.profileMsg())
	return nil
}

// Block refuses a peer for good: everything open is closed and future
// connections are dropped silently. Undo with Unblock.
func (m *Manager) Block(peerID string) error {
	m.mu.Lock()
	name := m.accepted[peerID]
	live, pend := m.unlinkLocked(peerID)
	if pend != nil {
		name = pend.name
	}
	if live != nil {
		name = live.name
	}
	delete(m.accepted, peerID)
	mapSet(&m.blocked, peerID, name)
	roster := m.rosterLocked()
	m.mu.Unlock()
	m.saveRoster(roster)

	live.close()
	pend.close()
	m.emit(map[string]any{"type": "peer-blocked", "peer": peerID, "name": name})
	return nil
}

// Unblock lets a peer request a chat again.
func (m *Manager) Unblock(peerID string) error {
	m.mu.Lock()
	if _, ok := m.blocked[peerID]; !ok {
		m.mu.Unlock()
		return errors.New("peer is not blocked")
	}
	delete(m.blocked, peerID)
	roster := m.rosterLocked()
	m.mu.Unlock()
	m.saveRoster(roster)
	m.emit(map[string]any{"type": "peer-unblocked", "peer": peerID})
	return nil
}

// BlockedPeer is one entry of ListBlocked.
type BlockedPeer struct {
	Peer string `json:"peer"`
	Name string `json:"name"`
}

// ListBlocked returns the blocked peers, stably sorted.
func (m *Manager) ListBlocked() []BlockedPeer {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]BlockedPeer, 0, len(m.blocked))
	for k, n := range m.blocked {
		out = append(out, BlockedPeer{Peer: k, Name: n})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Peer < out[j].Peer })
	return out
}

func mapSet[K comparable, V any](m *map[K]V, k K, v V) {
	if *m == nil {
		*m = make(map[K]V)
	}
	(*m)[k] = v
}
