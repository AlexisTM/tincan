package bridge

import (
	"context"
	"errors"
	"fmt"
	"net"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/ipn/ipnstate"
)

// Direct-only mode: the relay still carries the handshake and the disco
// traffic that finds a direct path, but no chat. A dialer waits for a
// direct path before its hello; an acceptor, which can't measure its
// own path, holds a hello that isn't marked direct until the dialer
// reports one. A conversation whose path falls back to the relay is
// closed and redialed. Magicsock has no knob to keep WireGuard data off
// DERP, so the gate is ours: between two path checks, and while
// magicsock revalidates a direct path, packets can still cross the
// relay, sealed end to end like everything else.

var errNoDirect = errors.New("No direct path (direct-only mode)")

const directPoll = 2 * time.Second

// SetDirectOnly switches direct-only mode live. Turning it on drops
// conversations last seen relayed; they redial and wait for a path.
func (m *Manager) SetDirectOnly(on bool) {
	m.directOnly.Store(on)
	if !on {
		return
	}
	for _, p := range m.snapshotPeers(true) {
		if !p.direct.Load() {
			m.logf("tincan: %v is relayed; dropping it for direct-only mode", p.id)
			m.removePeer(p)
		}
	}
}

func (m *Manager) probe(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
	m.mu.Lock()
	f := m.probeFn
	m.mu.Unlock()
	return f(ctx, cl)
}

func pathStatus(res *ipnstate.PingResult) *wireMsg {
	ms := int(res.LatencySeconds*1000 + 0.5)
	if ms < 1 {
		ms = 1
	}
	return &wireMsg{T: "status", Direct: res.Endpoint != "", Addr: res.Endpoint, Relay: res.DERPRegionCode, Ms: ms}
}

func heldEvent(peerID string, held bool) map[string]any {
	return map[string]any{"type": "peer-status", "peer": peerID, "direct": false, "held": held}
}

// notePath records a measured or reported path and passes it on, unless
// p is a stranger, closing p if direct-only mode can't keep it. Reports
// whether p stays.
func (m *Manager) notePath(p *peer, st *wireMsg) bool {
	p.direct.Store(st.Direct)
	if !st.Direct && m.directOnly.Load() {
		m.logf("tincan: path to %v fell back to the relay; closing", p.id)
		m.removePeer(p)
		return false
	}
	m.mu.Lock()
	stranger := m.pending[p.id] == p
	m.mu.Unlock()
	if stranger {
		return true
	}
	m.emit(map[string]any{
		"type": "peer-status", "peer": p.id,
		"direct": st.Direct, "addr": st.Addr, "relay": st.Relay,
		"latencyMs": st.Ms,
	})
	return true
}

// awaitDirect disco-pings until the path is direct, which the pings
// themselves help bring about. It reports false, without error, if
// direct-only mode is switched off meanwhile.
func (m *Manager) awaitDirect(cl *tailcat.Client, peerID string) (bool, error) {
	deadline := time.Now().Add(m.directWait)
	held := false
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		res, err := m.probe(ctx, cl)
		cancel()
		if err == nil && res.Endpoint != "" {
			return true, nil
		}
		if !m.directOnly.Load() {
			return false, nil
		}
		if !held {
			held = true
			m.emit(heldEvent(peerID, true))
		}
		if time.Now().After(deadline) {
			return false, errNoDirect
		}
		select {
		case <-time.After(directPoll):
		case <-m.stop:
			return false, errors.New("shutting down")
		}
	}
}

// reportPath streams our measured path to an acceptor that may be
// holding our hello, until the returned stop is called.
func (m *Manager) reportPath(conn net.Conn, cl *tailcat.Client) (stop func()) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			pctx, pcancel := context.WithTimeout(ctx, 4*time.Second)
			res, err := m.probe(pctx, cl)
			pcancel()
			if ctx.Err() != nil {
				return
			}
			if err == nil && writeMsgFrame(conn, pathStatus(res)) != nil {
				return
			}
			select {
			case <-time.After(directPoll):
			case <-ctx.Done():
				return
			case <-m.stop:
				return
			}
		}
	}()
	return func() {
		cancel()
		<-done
	}
}

// holdForDirect keeps an incoming stream silent, reading only the
// dialer's path reports, until one says direct or the mode goes off.
func (m *Manager) holdForDirect(conn net.Conn, peerID string) (direct bool, err error) {
	m.emit(heldEvent(peerID, true))
	defer func() {
		if err != nil {
			m.emit(heldEvent(peerID, false))
		}
	}()
	conn.SetDeadline(time.Now().Add(m.directWait))
	for {
		kind, payload, err := readFrame(conn, maxPendingFrame)
		if err != nil {
			return false, err
		}
		if kind != frameMsg {
			return false, errors.New("blob before hello")
		}
		msg, err := parseMsg(payload)
		if err != nil {
			return false, err
		}
		if msg.T != "status" {
			return false, fmt.Errorf("%q before hello", msg.T)
		}
		if msg.Direct || !m.directOnly.Load() {
			return msg.Direct, nil
		}
	}
}
