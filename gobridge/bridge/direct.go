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

// Direct-only mode: the relay carries only the handshake and disco. Magicsock
// can't keep WireGuard data off DERP, so the gate is ours.

var errNoDirect = errors.New("No direct path (direct-only mode)")

const (
	directPoll    = 2 * time.Second
	maxProbeFails = 3
	maxPathText   = 64
	maxPathMs     = 60_000
)

// SetDirectOnly switches direct-only mode live. Turning it on drops
// conversations known to be relayed and probes dialed ones not yet measured.
func (m *Manager) SetDirectOnly(on bool) {
	m.directOnly.Store(on)
	if !on {
		return
	}
	for _, p := range m.snapshotPeers(true) {
		switch {
		case p.direct.Load():
		case p.outgoing && !p.measured.Load():
			m.checkPath(p)
		default:
			m.logf("tincan: %v is relayed; dropping it for direct-only mode", p.id)
			m.removePeer(p)
		}
	}
}

type probeFunc func(context.Context, *tailcat.Client) (*ipnstate.PingResult, error)

func discoPing(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
	return cl.DiscoPing(ctx)
}

func (m *Manager) probe(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
	return (*m.probeFn.Load())(ctx, cl)
}

func pathStatus(res *ipnstate.PingResult) *wireMsg {
	ms := int(res.LatencySeconds*1000 + 0.5)
	if ms < 1 {
		ms = 1
	}
	return &wireMsg{T: "status", Direct: res.Endpoint != "", Addr: res.Endpoint, Relay: res.DERPRegionCode, Ms: ms}
}

// wirePath is a peer's path report, made safe to show.
func wirePath(msg *wireMsg) *wireMsg {
	return &wireMsg{
		T:      "status",
		Direct: msg.Direct,
		Addr:   truncUTF8(cleanText(msg.Addr), maxPathText),
		Relay:  truncUTF8(cleanText(msg.Relay), maxPathText),
		Ms:     min(max(msg.Ms, 0), maxPathMs),
	}
}

func heldEvent(peerID string, held bool) map[string]any {
	return map[string]any{"type": "peer-status", "peer": peerID, "direct": false, "held": held}
}

// notePath records a path and reports it, unless p is a stranger, closing p
// if direct-only mode can't keep it. Reports whether p stays.
func (m *Manager) notePath(p *peer, st *wireMsg) bool {
	p.direct.Store(st.Direct)
	p.measured.Store(true)
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

// awaitDirect disco-pings until the path is direct. It reports false,
// without error, if direct-only mode is switched off meanwhile.
func (m *Manager) awaitDirect(cl *tailcat.Client, peerID string) (bool, error) {
	deadline := time.Now().Add(m.directWait)
	held, fails := false, 0
	defer func() {
		if held {
			m.emit(heldEvent(peerID, false))
		}
	}()
	for {
		ctx, cancel := context.WithTimeout(m.life, 4*time.Second)
		res, err := m.probe(ctx, cl)
		cancel()
		if m.closed() {
			return false, errClosed
		}
		if err == nil && res.Endpoint != "" {
			return true, nil
		}
		if err == nil {
			fails = 0
		} else if fails++; fails >= maxProbeFails {
			return false, fmt.Errorf("peer unreachable: %w", err)
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
			return false, errClosed
		}
	}
}

// reportPath streams our measured path to an acceptor that may be
// holding our hello, until the returned stop is called. An acceptor that
// isn't holding answers before the first report.
func (m *Manager) reportPath(conn net.Conn, cl *tailcat.Client) (stop func()) {
	ctx, cancel := context.WithCancel(m.life)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			select {
			case <-time.After(directPoll):
			case <-ctx.Done():
				return
			}
			pctx, pcancel := context.WithTimeout(ctx, 4*time.Second)
			res, err := m.probe(pctx, cl)
			pcancel()
			if ctx.Err() != nil {
				return
			}
			if err == nil && writeMsgFrame(conn, pathStatus(res)) != nil {
				return
			}
		}
	}()
	return func() {
		cancel()
		<-done
	}
}

// reserveHold takes a slot for holding a stranger, sharing the pending cap
// so fresh keys can't pin unbounded held streams.
func (m *Manager) reserveHold() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if len(m.pending)+m.holding >= maxPendingPeers {
		return false
	}
	m.holding++
	return true
}

func (m *Manager) releaseHold() {
	m.mu.Lock()
	m.holding--
	m.mu.Unlock()
}

var errReleased = errors.New("direct-only mode switched off")

// holdReader reads a held stream in directPoll slices so the hold notices
// the mode going off; it lets go only between frames.
type holdReader struct {
	m     *Manager
	conn  net.Conn
	end   time.Time
	fresh bool // nothing of the current frame read yet
}

func (r *holdReader) Read(b []byte) (int, error) {
	for {
		dl := time.Now().Add(directPoll)
		if dl.After(r.end) {
			dl = r.end
		}
		r.conn.SetReadDeadline(dl)
		n, err := r.conn.Read(b)
		if n > 0 {
			r.fresh = false
			if isTimeout(err) {
				err = nil
			}
			return n, err
		}
		if !isTimeout(err) || !time.Now().Before(r.end) {
			return 0, err
		}
		if r.m.closed() {
			return 0, errClosed
		}
		if r.fresh && !r.m.directOnly.Load() {
			return 0, errReleased
		}
	}
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// holdForDirect keeps an incoming stream silent, reading only the
// dialer's path reports, until one says direct or the mode goes off.
// Only known peers get held events; strangers have no conversation yet.
func (m *Manager) holdForDirect(conn net.Conn, peerID string, known bool) (bool, error) {
	if known {
		m.emit(heldEvent(peerID, true))
		defer m.emit(heldEvent(peerID, false))
	}
	r := &holdReader{m: m, conn: conn, end: time.Now().Add(m.directWait)}
	for {
		r.fresh = true
		kind, payload, err := readFrame(r, maxPendingFrame)
		switch {
		case errors.Is(err, errReleased):
			return false, nil
		case isTimeout(err):
			conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			writeMsgFrame(conn, &wireMsg{T: "error", Code: "nodirect", Body: errNoDirect.Error()})
			return false, errNoDirect
		case err != nil:
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
