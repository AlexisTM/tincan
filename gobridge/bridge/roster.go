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
	Verified map[string]bool   `json:"verified,omitempty"` // safety number checked in person
}

// readRoster loads the roster without installing it.
func (m *Manager) readRoster() (rosterData, error) {
	var r rosterData
	err := m.loadJSON(rosterFile, &r)
	if errors.Is(err, os.ErrNotExist) {
		err = nil
	}
	return r, err
}

// saveRoster snapshots under saveMu, so the last write is the latest.
func (m *Manager) saveRoster() error {
	m.saveMu.Lock()
	defer m.saveMu.Unlock()
	m.mu.Lock()
	r := rosterData{maps.Clone(m.accepted), maps.Clone(m.blocked), maps.Clone(m.verified)}
	m.mu.Unlock()
	err := m.saveJSON(rosterFile, r)
	if err != nil {
		m.logf("tincan: saving roster: %v", err)
	}
	return err
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
	name, known := m.accepted[peerID]
	changed := !known || name != p.name
	mapSet(&m.accepted, peerID, p.name)
	texts := p.pendingTexts
	p.pendingTexts = nil
	profile := p.pendingProfile
	p.pendingProfile = nil
	m.mu.Unlock()

	if changed {
		m.saveRoster()
	}
	drop.close()
	m.emit(m.peerAddedEvent(live))
	if profile != nil {
		m.applyPeerProfile(live, profile)
	}
	for _, t := range texts {
		m.emit(messageEvent(p, t))
	}
	// The accept is committed; a dead conn just means they hear on redial.
	if live == p {
		if err := p.writeMsg(&wireMsg{T: "accepted"}); err != nil {
			m.logf("tincan: telling %v they're accepted: %v", peerID, err)
		}
	}
	// A dial racing this can tie-break live away, so follow the survivor.
	go func() {
		for to := live; to != nil; {
			err := to.writeMsg(m.profileMsg())
			for _, t := range texts {
				if err == nil {
					err = to.writeMsg(&wireMsg{T: "ack", Ref: t.ID})
				}
			}
			if err == nil {
				return
			}
			m.mu.Lock()
			next := m.peers[peerID]
			m.mu.Unlock()
			if next == to {
				return
			}
			to = next
		}
	}()
	return nil
}

// Ignore drops a pending request without blocking; they may ask again.
func (m *Manager) Ignore(peerID string) error {
	m.mu.Lock()
	p := m.pending[peerID]
	delete(m.pending, peerID)
	m.mu.Unlock()
	if p == nil {
		return fmt.Errorf("no pending request from %v", peerID)
	}
	m.dropPeer(p, false)
	return nil
}

// SetVerified records whether the user checked this peer's safety
// number.
func (m *Manager) SetVerified(peerID string, verified bool) error {
	m.mu.Lock()
	if m.verified[peerID] == verified {
		m.mu.Unlock()
		return nil
	}
	if verified {
		mapSet(&m.verified, peerID, true)
	} else {
		delete(m.verified, peerID)
	}
	m.mu.Unlock()
	return m.saveRoster()
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
	m.mu.Unlock()
	err := m.saveRoster()

	live.close()
	pend.close()
	m.emit(map[string]any{"type": "peer-blocked", "peer": peerID, "name": name})
	return err
}

// Unblock lets a peer request a chat again.
func (m *Manager) Unblock(peerID string) error {
	m.mu.Lock()
	if _, ok := m.blocked[peerID]; !ok {
		m.mu.Unlock()
		return errors.New("peer is not blocked")
	}
	delete(m.blocked, peerID)
	m.mu.Unlock()
	err := m.saveRoster()
	m.emit(map[string]any{"type": "peer-unblocked", "peer": peerID})
	return err
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
