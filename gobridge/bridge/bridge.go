// Package bridge implements tincan's chat layer over the tailcat
// transport. Each app runs a tailcat server (its address is the user's
// identity) and dials peers as a client; one TCP stream per peer
// carries CBOR messages and file chunks (proto.go). Everything is
// reported as JSON events, so FFI callers stay language-agnostic.
package bridge

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"github.com/tailscale/tailcat"
	"tailscale.com/ipn/ipnstate"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
	"tailscale.com/types/logger"
	"tailscale.com/wgengine/filter"
)

type Config struct {
	StateDir    string // identity key lives here
	DownloadDir string // received files land here
	Name        string // display name sent in hello

	// Region skips the DERP map fetch. Tests point it at a local relay.
	Region *tailcfg.DERPRegion

	// DERPHost routes through one relay of the user's own, by hostname.
	// It wins over DERPMapURL, which serves a whole map of them. See
	// ParseRelay for the single setting the host keeps.
	DERPHost   string
	DERPMapURL string

	// Vault encrypts everything written under StateDir and DownloadDir.
	// Required: the bridge does not write plaintext.
	Vault *Vault

	// DirectOnly keeps chat off the relay: it only introduces peers.
	// See SetDirectOnly.
	DirectOnly bool

	Logf logger.Logf // nil means discard
}

type Manager struct {
	cfg  Config
	logf logger.Logf
	ev   *eventQueue
	inst string // this process, in hellos

	priv   *tailcat.PrivateKey
	selfID string

	// lifeMu serializes bringing the server up and down, and guards
	// retrying. Never taken while holding mu.
	lifeMu   sync.Mutex
	retrying bool

	mu         sync.Mutex
	server     *tailcat.Server
	startErr   error // why the server is down, while it is
	addr       tailcat.ConnBlob
	name       string            // display name sent in hellos and profiles
	desc       string            // profile description/bio
	status     string            // profile status line
	avatar     []byte            // profile picture bytes (any image format)
	avatarPath string            // where avatar is sealed on disk
	peers      map[string]*peer  // accepted, live conversations
	pending    map[string]*peer  // incoming requests awaiting accept/block
	accepted   map[string]string // persisted roster: peer key -> name
	blocked    map[string]string
	verified   map[string]bool
	active     string                          // the chat on screen, pinged more often
	insts      map[string]map[string]time.Time // peer -> instances lately seen
	lastInst   map[string]string
	dupes      map[string]dupe

	probeFn func(context.Context, *tailcat.Client) (*ipnstate.PingResult, error) // mu; tests fake paths

	directOnly atomic.Bool
	directWait time.Duration // how long a held dial waits for a direct path

	saveMu sync.Mutex // one roster writer at a time

	recvMu sync.Mutex
	recvs  map[string]*recvFile // by recvKey

	sendMu sync.Mutex
	sends  map[string]*sendCancel // outgoing transfers, by recvKey

	stop      chan struct{}
	closeOnce sync.Once
}

type peer struct {
	id       string // stable identity: peer's server node key string
	name     string
	token    string // how to reach them again, once known
	outgoing bool
	inst     string
	feat     []string

	conn      net.Conn
	client    *tailcat.Client // outgoing only
	writeMu   sync.Mutex
	done      chan struct{} // closed with the connection
	closeOnce sync.Once

	// Buffered while awaiting acceptance, replayed on Accept. Manager.mu.
	pendingTexts []*wireMsg

	// Applied on Accept. Manager.mu.
	pendingProfile *wireMsg

	// Outgoing peers: the far side hasn't accepted us yet. Manager.mu.
	remotePending bool

	sendSlots chan struct{}
	offerMu   sync.Mutex
	offers    map[string]chan int64 // file-offers awaiting file-resume

	kaBusy, pingBusy atomic.Bool
	lastPing         time.Time // statusLoop only
	toldDupe         atomic.Bool

	// The last known path; in direct-only mode nothing is written while
	// it is relayed.
	direct     atomic.Bool
	onlyDirect *atomic.Bool
}

func newPeer(id, name string, conn net.Conn, hello *wireMsg) *peer {
	return &peer{
		id:        id,
		name:      cleanName(name),
		conn:      conn,
		inst:      hello.Inst,
		feat:      hello.Feat,
		done:      make(chan struct{}),
		sendSlots: make(chan struct{}, maxSendsPerPeer),
		offers:    make(map[string]chan int64),
	}
}

func (p *peer) close() {
	if p == nil {
		return
	}
	p.closeOnce.Do(func() { close(p.done) })
	p.conn.Close()
	if p.client != nil {
		p.client.Close()
	}
}

func (p *peer) has(feature string) bool { return slices.Contains(p.feat, feature) }

const maxPendingTexts = 25

func New(cfg Config) *Manager {
	logf := cfg.Logf
	if logf == nil {
		logf = logger.Discard
	}
	inst := make([]byte, 8)
	rand.Read(inst)
	m := &Manager{
		cfg:     cfg,
		logf:    logf,
		name:    cfg.Name,
		ev:      newEventQueue(),
		inst:    hex.EncodeToString(inst),
		peers:   make(map[string]*peer),
		pending: make(map[string]*peer),
		recvs:   make(map[string]*recvFile),
		sends:   make(map[string]*sendCancel),
		stop:    make(chan struct{}),
		probeFn: func(ctx context.Context, cl *tailcat.Client) (*ipnstate.PingResult, error) {
			return cl.DiscoPing(ctx)
		},
		directWait: time.Minute,
	}
	m.directOnly.Store(cfg.DirectOnly)
	return m
}

// ParseRelay splits the host's one relay setting: an http(s) URL names
// a relay map, anything else a single relay's hostname.
func ParseRelay(relay string) (host, mapURL string) {
	relay = strings.TrimSpace(relay)
	if strings.HasPrefix(relay, "http://") || strings.HasPrefix(relay, "https://") {
		return "", relay
	}
	return relay, ""
}

// Address is the connection token; valid after Start.
func (m *Manager) Address() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return string(m.addr)
}

const identityFile = "identity.json"

// loadJSON decrypts StateDir/name into v. A missing file is reported
// as os.ErrNotExist.
func (m *Manager) loadJSON(name string, v any) error {
	j, err := m.cfg.Vault.ReadFile(filepath.Join(m.cfg.StateDir, name))
	if err != nil {
		return err
	}
	if err := json.Unmarshal(j, v); err != nil {
		return fmt.Errorf("corrupt %s: %w", name, err)
	}
	return nil
}

func (m *Manager) saveJSON(name string, v any) error {
	j, err := json.MarshalIndent(v, "", "\t")
	if err != nil {
		return err
	}
	return m.cfg.Vault.WriteFile(filepath.Join(m.cfg.StateDir, name), j, 0600)
}

// loadIdentity reads our key from the vault, minting one if there is
// none yet.
func (m *Manager) loadIdentity() (pk *tailcat.PrivateKey, fresh bool, err error) {
	pk = new(tailcat.PrivateKey)
	err = m.loadJSON(identityFile, pk)
	if errors.Is(err, os.ErrNotExist) {
		return tailcat.NewPrivateKey(), true, nil
	}
	// Minting a new key on any other error would silently replace the
	// account.
	return pk, false, err
}

// keyCopy is a copy of our key for building a server, so a failed start
// leaves m.priv alone.
func (m *Manager) keyCopy() *tailcat.PrivateKey {
	m.mu.Lock()
	defer m.mu.Unlock()
	pk := *m.priv
	return &pk
}

func (m *Manager) saveIdentity() error {
	m.mu.Lock()
	pk := *m.priv
	m.mu.Unlock()
	return m.saveJSON(identityFile, &pk)
}

// Open loads the account from the vault; Start then brings the
// transport up. Only Open's failures are fatal.
func (m *Manager) Open() error {
	if m.cfg.Vault == nil {
		return errors.New("no vault: unlock before starting")
	}
	if err := os.MkdirAll(m.cfg.StateDir, 0700); err != nil {
		return err
	}
	if err := os.MkdirAll(m.cfg.DownloadDir, 0700); err != nil {
		return err
	}
	pk, fresh, err := m.loadIdentity()
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.priv = pk
	m.mu.Unlock()
	if fresh {
		if err := m.saveIdentity(); err != nil {
			return err
		}
	}
	r, err := m.readRoster()
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.accepted, m.blocked, m.verified = r.Accepted, r.Blocked, r.Verified
	m.mu.Unlock()
	m.applyProfile(m.readProfile())
	go sweepStale(m.cfg.StateDir, m.cfg.DownloadDir)
	go m.statusLoop()
	go m.keepaliveLoop()
	return nil
}

// Start brings up the server, returning the server-started event. When
// it can't (launched offline, say) it keeps retrying in the background
// and reports transport-error or server-started events.
func (m *Manager) Start() (map[string]any, error) {
	m.lifeMu.Lock()
	defer m.lifeMu.Unlock()
	srv, pk, err := m.bringUp()
	if err != nil {
		m.downLocked(err)
		return nil, err
	}
	return m.installServer(srv, pk), nil
}

// downLocked records why the server is down and keeps trying to bring
// it up; lifeMu held.
func (m *Manager) downLocked(err error) {
	m.mu.Lock()
	m.startErr = err
	m.mu.Unlock()
	if !m.retrying {
		m.retrying = true
		go m.keepStarting()
	}
}

func (m *Manager) keepStarting() {
	for attempt := 0; ; attempt++ {
		select {
		case <-m.stop:
			return
		case <-time.After(min(time.Minute, 5*time.Second<<min(attempt, 4))):
		}
		m.lifeMu.Lock()
		if m.running() {
			m.retrying = false
			m.lifeMu.Unlock()
			return
		}
		srv, pk, err := m.bringUp()
		if err == nil && m.closed() {
			srv.Close()
			m.lifeMu.Unlock()
			return
		}
		if err == nil {
			m.retrying = false
			ev := m.installServer(srv, pk)
			m.lifeMu.Unlock()
			m.emit(ev)
			return
		}
		m.mu.Lock()
		m.startErr = err
		m.mu.Unlock()
		m.lifeMu.Unlock()
		m.logf("tincan: transport start failed: %v", err)
		m.emit(map[string]any{"type": "transport-error", "error": err.Error()})
	}
}

func (m *Manager) closed() bool {
	select {
	case <-m.stop:
		return true
	default:
		return false
	}
}

func (m *Manager) running() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.server != nil
}

// Started is the server-started event, or why the server is down. It
// waits out a start in flight, whose caller may be gone.
func (m *Manager) Started() (map[string]any, error) {
	m.lifeMu.Lock()
	defer m.lifeMu.Unlock()
	m.mu.Lock()
	up, err := m.server != nil, m.startErr
	m.mu.Unlock()
	if !up {
		if err == nil {
			err = errors.New("transport not started")
		}
		return nil, err
	}
	return m.startedEvent(), nil
}

// bringUp starts a server on our key, returning the key to install it
// with; lifeMu held.
func (m *Manager) bringUp() (*tailcat.Server, *tailcat.PrivateKey, error) {
	pk := m.keyCopy()
	srv, err := m.newServer(pk)
	if err != nil && m.cfg.Region == nil && m.cfg.DERPHost == "" &&
		pk.Public.RegionID > 0 && m.regionGone(pk.Public.RegionID) {
		// A pinned region can vanish from the DERP map; repick rather
		// than stay wedged. Repicking changes the address, so a network
		// that is merely down must not get here.
		m.logf("tincan: pinned DERP region failed (%v); picking a new one", err)
		pk.Public.RegionID = 0
		srv, err = m.newServer(pk)
	}
	return srv, pk, err
}

// regionGone reports whether the DERP map could be fetched and lacks id.
func (m *Manager) regionGone(id tailcfg.DERPRegionID) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	dm, err := tailcat.FetchDERPMap(ctx, derpOpts(m.cfg.DERPMapURL)...)
	if err != nil {
		return false
	}
	_, ok := dm.Regions[id]
	return !ok
}

// identityKey is our long-term private key, which ResetIdentity and
// Restart swap out.
func (m *Manager) identityKey() key.NodePrivate {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.priv.Private
}

// A tunnel that dies without FINs (crash, network loss) would leave the
// other side blocked on a read forever, so both ends keepalive.
const (
	keepaliveEvery = 15 * time.Second
	readIdleLimit  = 50 * time.Second
)

func (m *Manager) keepaliveLoop() {
	tick := time.NewTicker(keepaliveEvery)
	defer tick.Stop()
	for {
		select {
		case <-m.stop:
			return
		case <-tick.C:
		}
		for _, p := range m.snapshotPeers(true) {
			if !p.kaBusy.CompareAndSwap(false, true) {
				continue // the last one is still stuck; its deadline will fire
			}
			go func(p *peer) {
				defer p.kaBusy.Store(false)
				p.writeMsg(&wireMsg{T: "ka"}) // a failure closes the conn, which the read loop reports
			}(p)
		}
	}
}

// snapshotPeers copies out the live peers, and pending ones if asked.
func (m *Manager) snapshotPeers(withPending bool) []*peer {
	m.mu.Lock()
	defer m.mu.Unlock()
	ps := slices.Collect(maps.Values(m.peers))
	if withPending {
		ps = slices.AppendSeq(ps, maps.Values(m.pending))
	}
	return ps
}

// installServer makes srv, built on pk, current and returns the
// server-started event. It persists pk, whose key or pinned region may
// be new.
func (m *Manager) installServer(srv *tailcat.Server, pk *tailcat.PrivateKey) map[string]any {
	m.mu.Lock()
	m.priv = pk
	m.server = srv
	m.startErr = nil
	m.addr = srv.ConnBlob()
	m.selfID = pk.Private.Public().String()
	m.mu.Unlock()
	if err := m.saveIdentity(); err != nil {
		m.logf("tincan: saving identity: %v", err)
	}
	return m.startedEvent()
}

type storedProfile struct {
	Name   string `json:"name"`
	Desc   string `json:"description"`
	Status string `json:"status"`
}

const profileFile = "profile.json"

type loadedProfile struct {
	storedProfile
	avatar     []byte
	avatarPath string
}

// readProfile reads the profile from the vault, at startup and when a
// restored account replaces it.
func (m *Manager) readProfile() loadedProfile {
	var sp storedProfile
	if m.loadJSON(profileFile, &sp) != nil || sp.Name == "" {
		sp = storedProfile{Name: m.cfg.Name}
	}
	lp := loadedProfile{storedProfile: sp}
	lp.avatarPath = m.cfg.Vault.selfAvatar()
	if lp.avatarPath != "" {
		lp.avatar, _ = m.cfg.Vault.ReadMedia(lp.avatarPath)
	}
	if len(lp.avatar) == 0 {
		lp.avatarPath = ""
	}
	return lp
}

func (m *Manager) applyProfile(lp loadedProfile) {
	m.mu.Lock()
	m.name, m.desc, m.status = lp.Name, lp.Desc, lp.Status
	m.avatar, m.avatarPath = lp.avatar, lp.avatarPath
	m.mu.Unlock()
}

func (m *Manager) startedEvent() map[string]any {
	ev := m.selfProfileEvent()
	m.mu.Lock()
	defer m.mu.Unlock()
	ev["type"] = "server-started"
	ev["address"] = string(m.addr)
	return ev
}

// selfProfileEvent reports our own profile, with avatarPath empty when
// there is no picture.
func (m *Manager) selfProfileEvent() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{
		"type":        "self-profile",
		"name":        m.name,
		"description": m.desc,
		"status":      m.status,
		"avatarPath":  m.avatarPath,
	}
}

// SetProfile stores the profile and pushes it to connected peers.
// avatarPath points at a plaintext image the host just prepared;
// avatarChanged distinguishes "no new picture" from "remove it".
func (m *Manager) SetProfile(name, desc, status, avatarPath string, avatarChanged bool) error {
	var avatar []byte
	if avatarChanged && avatarPath != "" {
		b, err := os.ReadFile(avatarPath)
		if err != nil {
			return err
		}
		if len(b) > maxAvatarBytes {
			return fmt.Errorf("profile picture is %d bytes; limit is %d", len(b), maxAvatarBytes)
		}
		if err := checkAvatar(b); err != nil {
			return err
		}
		avatar = b
	}

	m.mu.Lock()
	m.name, m.desc, m.status = name, desc, status
	if avatarChanged {
		m.avatar = avatar
	}
	m.mu.Unlock()

	if err := m.saveJSON(profileFile, storedProfile{Name: name, Desc: desc, Status: status}); err != nil {
		m.logf("tincan: saving profile: %v", err)
	}
	if avatarChanged {
		path, err := m.cfg.Vault.storeAvatar(selfOwner, avatar)
		if err != nil {
			m.logf("tincan: saving avatar: %v", err)
		}
		m.mu.Lock()
		m.avatarPath = path
		m.mu.Unlock()
	}
	m.emit(m.selfProfileEvent())
	msg, err := encodeMsg(m.profileMsg())
	if err != nil {
		return err
	}
	for _, p := range m.snapshotPeers(false) {
		go p.writeEncoded(msg)
	}
	return nil
}

// profileMsg snapshots the profile as a wire message.
func (m *Manager) profileMsg() *wireMsg {
	m.mu.Lock()
	defer m.mu.Unlock()
	return &wireMsg{
		T:        "profile",
		Name:     m.name,
		SelfAddr: string(m.addr),
		Desc:     m.desc,
		Status:   m.status,
		Avatar:   slices.Clone(m.avatar),
	}
}

// teardown drops the server and all connections, announcing the
// closures itself: the maps are cleared before the read loops notice.
func (m *Manager) teardown() {
	m.mu.Lock()
	old := m.server
	m.server = nil
	live := slices.Collect(maps.Values(m.peers))
	pend := slices.Collect(maps.Values(m.pending))
	m.peers = make(map[string]*peer)
	m.pending = make(map[string]*peer)
	m.mu.Unlock()

	for _, p := range live {
		m.dropPeer(p, true)
	}
	for _, p := range pend {
		m.dropPeer(p, false)
	}
	if old != nil {
		// Let the FINs flush through the still-running tunnel first.
		time.Sleep(300 * time.Millisecond)
		old.Close()
	}
}

// replaceServer drops the running server, if any, for srv, built on
// pk; lifeMu held. Until then the old server keeps serving, and
// verifying hellos, with the old key.
func (m *Manager) replaceServer(srv *tailcat.Server, pk *tailcat.PrivateKey) map[string]any {
	m.teardown()
	return m.installServer(srv, pk)
}

// ResetIdentity swaps in a fresh key pair: the old address is dead for
// good and every connection drops. The roster and pinned region stay.
func (m *Manager) ResetIdentity() (map[string]any, error) {
	m.lifeMu.Lock()
	defer m.lifeMu.Unlock()
	pk := tailcat.NewPrivateKey()
	pk.Public.RegionID = m.keyCopy().Public.RegionID
	srv, err := m.newServer(pk)
	if err != nil {
		return nil, fmt.Errorf("restarting with new identity: %w", err)
	}
	return m.replaceServer(srv, pk), nil
}

// Restart rebuilds the server from what is now on disk: the
// restore-account path, once the caller has written the files. Nothing
// changes unless all of it loads.
func (m *Manager) Restart() (map[string]any, error) {
	m.lifeMu.Lock()
	defer m.lifeMu.Unlock()
	pk, _, err := m.loadIdentity()
	if err != nil {
		return nil, err
	}
	r, err := m.readRoster()
	if err != nil {
		return nil, err
	}
	lp := m.readProfile()
	srv, err := m.newServer(pk)
	m.teardown()
	m.mu.Lock()
	m.accepted, m.blocked, m.verified = r.Accepted, r.Blocked, r.Verified
	m.mu.Unlock()
	m.applyProfile(lp)
	if err != nil {
		// The old account is gone; retry as the restored one.
		m.mu.Lock()
		m.priv = pk
		m.mu.Unlock()
		m.downLocked(err)
		return nil, fmt.Errorf("restarting: %w", err)
	}
	return m.installServer(srv, pk), nil
}

// newServer starts a tailcat server on pk, pinning the nearest region
// into pk on first run; lifeMu held. It pins the region's real id, not
// the one parsed back from our own token: embedding renumbers regions
// from 1.
func (m *Manager) newServer(pk *tailcat.PrivateKey) (*tailcat.Server, error) {
	srv := &tailcat.Server{
		Key:  pk.Private,
		Logf: m.logf,
		OnTCP: func(port uint16) func(net.Conn) {
			if port != ChatPort {
				return nil
			}
			return m.handleIncoming
		},
		ServedTCPPorts: []filter.PortRange{{First: ChatPort, Last: ChatPort}},
	}
	switch {
	case m.cfg.Region != nil:
		srv.Region = m.cfg.Region
	case m.cfg.DERPHost != "":
		// A relay of the user's own: no map to fetch, and the region id
		// is local to the address we hand out.
		srv.Region = &tailcfg.DERPRegion{
			RegionID:   customRegionID,
			RegionCode: "custom",
			Nodes: []*tailcfg.DERPNode{{
				Name:     m.cfg.DERPHost,
				RegionID: customRegionID,
				HostName: m.cfg.DERPHost,
			}},
		}
	case pk.Public.RegionID > 0:
		srv.RegionID = pk.Public.RegionID
	default:
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		reg, err := pickNearestRegion(ctx, m.cfg.DERPMapURL, m.logf)
		if err != nil {
			return nil, fmt.Errorf("picking DERP region: %w", err)
		}
		srv.Region = reg
		pk.Public.RegionID = reg.RegionID // persisted by installServer
	}
	srv.DERPMapURL = m.cfg.DERPMapURL
	if err := srv.Start(); err != nil {
		return nil, err
	}
	return srv, nil
}

const customRegionID = 900

// SetRelay switches the relay the server listens on. The key is kept,
// but the address embeds the relay, so it changes and old copies of it
// stop working. If a running server's replacement fails, the previous
// relay stays in use. With no server running there is nothing to keep:
// the new relay stays, starting is retried on it, and the result is
// empty, as the server-started event comes later.
func (m *Manager) SetRelay(host, mapURL string) (map[string]any, error) {
	m.lifeMu.Lock()
	defer m.lifeMu.Unlock()
	pk := m.keyCopy()
	pk.Public.RegionID = 0 // it belongs to the relay we are leaving
	m.mu.Lock()
	prevHost, prevMap := m.cfg.DERPHost, m.cfg.DERPMapURL
	m.cfg.DERPHost, m.cfg.DERPMapURL = host, mapURL
	m.mu.Unlock()
	srv, err := m.newServer(pk)
	if err == nil {
		return m.replaceServer(srv, pk), nil
	}
	if m.running() {
		m.mu.Lock()
		m.cfg.DERPHost, m.cfg.DERPMapURL = prevHost, prevMap
		m.mu.Unlock()
		return nil, fmt.Errorf("switching relay: %w", err)
	}
	m.mu.Lock()
	m.priv = pk
	m.mu.Unlock()
	m.downLocked(err)
	m.emit(map[string]any{"type": "transport-error", "error": err.Error()})
	return nil, nil
}

// Close shuts everything down. The events channel stays open.
func (m *Manager) Close() error {
	m.closeOnce.Do(func() {
		close(m.stop)
		for _, p := range m.snapshotPeers(true) {
			p.close()
		}
		m.mu.Lock()
		srv := m.server
		m.server = nil
		m.mu.Unlock()
		if srv != nil {
			srv.Close()
		}
	})
	return nil
}

func (m *Manager) hello(connKey string, proof []byte) *wireMsg {
	m.mu.Lock()
	defer m.mu.Unlock()
	return &wireMsg{
		T:        "hello",
		V:        protoVersion,
		VMin:     protoMin,
		VMax:     protoVersion,
		Feat:     features,
		Inst:     m.inst,
		Name:     m.name,
		Key:      m.selfID,
		ConnKey:  connKey,
		Proof:    proof,
		SelfAddr: string(m.addr),
	}
}

// helloProof is what a dialer seals from its identity key to the
// server's: anyone can claim a key in a hello, only its owner can seal.
// connKey is checked against the tunnel, so a proof is only good on the
// connection it was made for.
func helloProof(connKey string) []byte { return []byte("tincan hello v2 " + connKey) }

// verifyHello checks an incoming hello's proof and returns its key in
// canonical form, so a re-spelled key can't dodge the block list.
func (m *Manager) verifyHello(h *wireMsg, conn net.Conn) (string, error) {
	var pub, ck key.NodePublic
	if err := pub.UnmarshalText([]byte(h.Key)); err != nil || pub.IsZero() {
		return "", fmt.Errorf("bad identity key %q", h.Key)
	}
	if err := ck.UnmarshalText([]byte(h.ConnKey)); err != nil || !fromTunnelOf(conn, ck) {
		return "", fmt.Errorf("hello from %v names a connection key that isn't the tunnel's", pub.ShortString())
	}
	plain, ok := m.identityKey().OpenFrom(pub, h.Proof)
	if !ok || string(plain) != string(helloProof(h.ConnKey)) {
		return "", fmt.Errorf("hello from %v carries no valid proof of its key", pub.ShortString())
	}
	return pub.String(), nil
}

// fromTunnelOf reports whether conn comes from the WireGuard peer k.
// tailcat gives each node an address derived from its key and
// WireGuard drops packets from any other source, so the address
// authenticates the key. This mirrors tailcat's tcAddrForKey.
func fromTunnelOf(conn net.Conn, k key.NodePublic) bool {
	ra, ok := conn.RemoteAddr().(*net.TCPAddr)
	if !ok {
		return false
	}
	var a [16]byte
	copy(a[:], []byte{0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0})
	r := k.Raw32()
	copy(a[6:], r[:10])
	return ra.AddrPort().Addr().Unmap() == netip.AddrFrom16(a)
}

// negotiate checks that a hello's protocol range overlaps ours.
func negotiate(h *wireMsg) error {
	lo, hi := h.VMin, h.VMax
	if hi == 0 {
		lo, hi = h.V, h.V // before ranges, one version
	}
	if max(lo, protoMin) > min(hi, protoVersion) {
		return fmt.Errorf("they run protocol v%d to v%d, this app v%d to v%d; one of you needs to update", lo, hi, protoMin, protoVersion)
	}
	return nil
}

func (m *Manager) peerError(peerID string, msg *wireMsg) {
	m.emit(map[string]any{"type": "peer-error", "peer": peerID, "code": msg.Code, "body": msg.Body})
	if msg.Code == "duplicate-identity" {
		m.emit(map[string]any{"type": "identity-conflict"})
	}
}

// Connect dials a peer and waits for the outcome, returning their id.
// Reaching someone offline takes up to 45s to fail.
func (m *Manager) Connect(token string) (peerID string, err error) {
	server, err := m.dialTarget(token)
	if err != nil {
		return "", err
	}
	id, err := m.dial(token, server)
	if err != nil {
		m.emit(map[string]any{"type": "connect-error", "peer": server.String(), "error": err.Error()})
	}
	return id, err
}

// dialTarget checks token is someone we may dial, returning their key.
func (m *Manager) dialTarget(token string) (key.NodePublic, error) {
	ci, err := tailcat.ParseConnBlob(tailcat.ConnBlob(token))
	if err != nil {
		return key.NodePublic{}, fmt.Errorf("not a valid address: %w", err)
	}
	server := ci.ServerPublic.NodePublic
	if server == m.identityKey().Public() {
		return key.NodePublic{}, errors.New("that is your own address")
	}
	m.mu.Lock()
	_, isBlocked := m.blocked[server.String()]
	m.mu.Unlock()
	if isBlocked {
		return key.NodePublic{}, errors.New("you blocked this peer; unblock them first")
	}
	return server, nil
}

// dial connects to server and exchanges hellos, returning their id.
func (m *Manager) dial(token string, server key.NodePublic) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	cl := tailcat.NewClient(tailcat.ConnBlob(token))
	cl.Logf = m.logf

	// The server's Start returns before its relay connection is up, and
	// each ping sends exactly one handshake, so retry until one lands.
	for {
		if _, err := cl.Ping(ctx); err == nil {
			break
		} else if ctx.Err() != nil {
			cl.Close()
			return "", fmt.Errorf("peer unreachable: %w", err)
		}
		select {
		case <-time.After(time.Second):
		case <-ctx.Done():
		}
	}

	direct := false
	if m.directOnly.Load() {
		var err error
		if direct, err = m.awaitDirect(cl, server.String()); err != nil {
			cl.Close()
			return "", err
		}
		ctx, cancel = context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
	}

	conn, err := cl.DialTCPPort(ctx, ChatPort)
	if err != nil {
		cl.Close()
		return "", fmt.Errorf("dialing peer: %w", err)
	}

	wait := 20 * time.Second
	if !direct {
		wait += m.directWait // a direct-only acceptor may hold the hello
	}
	conn.SetDeadline(time.Now().Add(wait))
	connKey := cl.PublicKey().String()
	hello := m.hello(connKey, m.identityKey().SealTo(server, helloProof(connKey)))
	hello.Direct = direct
	if err := writeMsgFrame(conn, hello); err != nil {
		conn.Close()
		cl.Close()
		return "", fmt.Errorf("sending hello: %w", err)
	}
	stopReport := func() {}
	if !direct {
		stopReport = m.reportPath(conn, cl)
	}
	theirs, err := readHello(conn)
	stopReport()
	switch {
	case err != nil:
	case theirs.T == "error":
		m.peerError(server.String(), theirs)
		err = errors.New(theirs.Body)
	case theirs.Key != server.String():
		// WireGuard proved who answered; the hello's key must agree.
		err = fmt.Errorf("peer claims key %q, not the address's", theirs.Key)
	default:
		if err = negotiate(theirs); err != nil {
			writeMsgFrame(conn, &wireMsg{T: "error", Code: "version", Body: err.Error()})
			m.peerError(server.String(), &wireMsg{Code: "version", Body: err.Error()})
		}
	}
	if err != nil {
		conn.Close()
		cl.Close()
		return "", fmt.Errorf("reading hello: %w", err)
	}
	conn.SetDeadline(time.Time{})

	p := newPeer(theirs.Key, theirs.Name, conn, theirs)
	p.token = token
	p.outgoing = true
	p.client = cl
	p.direct.Store(direct)
	p.onlyDirect = &m.directOnly
	// Dialing someone is implicit acceptance of them, and answers any
	// request of theirs still waiting.
	m.mu.Lock()
	mapSet(&m.accepted, p.id, p.name)
	_, asked := m.pending[p.id]
	m.mu.Unlock()
	m.saveRoster()
	if asked {
		m.Accept(p.id)
	}
	if m.addPeer(p) {
		go m.readLoop(p)
		go p.writeMsg(m.profileMsg())
	}
	return p.id, nil
}

func (m *Manager) handleIncoming(conn net.Conn) {
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	theirs, err := readHello(conn)
	if err == nil && theirs.T != "hello" {
		err = fmt.Errorf("first message is %q, not hello", theirs.T)
	}
	if err == nil {
		theirs.Key, err = m.verifyHello(theirs, conn)
	}
	if err != nil {
		m.logf("tincan: incoming hello: %v", err)
		conn.Close()
		return
	}

	m.mu.Lock()
	_, isBlocked := m.blocked[theirs.Key]
	_, isAccepted := m.accepted[theirs.Key]
	m.mu.Unlock()
	if isBlocked {
		// Silence, so a blocked peer can't tell us from an offline one.
		conn.Close()
		return
	}
	if err := negotiate(theirs); err != nil {
		writeMsgFrame(conn, &wireMsg{T: "error", Code: "version", Body: err.Error()})
		conn.Close()
		m.peerError(theirs.Key, &wireMsg{Code: "version", Body: err.Error()})
		return
	}
	direct := theirs.Direct
	if !direct && m.directOnly.Load() {
		if direct, err = m.holdForDirect(conn, theirs.Key); err != nil {
			m.logf("tincan: held connection from %v: %v", theirs.Key, err)
			conn.Close()
			return
		}
	}

	if err := writeMsgFrame(conn, m.hello("", nil)); err != nil {
		conn.Close()
		return
	}
	conn.SetDeadline(time.Time{})

	p := newPeer(theirs.Key, theirs.Name, conn, theirs)
	p.direct.Store(direct)
	p.onlyDirect = &m.directOnly
	if ownToken(theirs.SelfAddr, p.id) {
		p.token = theirs.SelfAddr
	}
	if isAccepted {
		if err := p.writeMsg(&wireMsg{T: "accepted"}); err != nil {
			conn.Close()
			return
		}
		if !m.addPeer(p) {
			return
		}
		go p.writeMsg(m.profileMsg())
	} else {
		// Fresh keys are free, so requests are cheap to spam: check the
		// cap and take the slot in one go.
		m.mu.Lock()
		if len(m.pending) >= maxPendingPeers && m.pending[p.id] == nil {
			m.mu.Unlock()
			conn.Close()
			return
		}
		old := m.installPeerLocked(p, true)
		m.mu.Unlock()
		old.close()
		m.emit(m.peerRequestEvent(p))
		if err := p.writeMsg(&wireMsg{T: "pending"}); err != nil {
			m.removePeer(p)
			return
		}
	}
	m.readLoop(p) // handleIncoming runs on its own goroutine already
}

// ownToken reports whether token is a valid address of identity id.
func ownToken(token, id string) bool {
	if token == "" {
		return false
	}
	ci, err := tailcat.ParseConnBlob(tailcat.ConnBlob(token))
	return err == nil && ci.ServerPublic.String() == id
}

const maxPendingPeers = 64

// readHello reads the first message, a hello or an error.
func readHello(conn net.Conn) (*wireMsg, error) {
	kind, payload, err := readFrame(conn, maxPendingFrame)
	if err != nil {
		return nil, err
	}
	if kind != frameMsg {
		return nil, errors.New("first frame not a message")
	}
	msg, err := parseMsg(payload)
	if err != nil {
		return nil, err
	}
	switch msg.T {
	case "error":
		msg.Body = capBody(cleanText(msg.Body))
		return msg, nil
	case "hello":
	default:
		return nil, fmt.Errorf("first message is %q, not hello", msg.T)
	}
	if msg.Key == "" {
		return nil, errors.New("hello lacks an identity key")
	}
	return msg, nil
}

func capBody(s string) string {
	if len(s) <= maxBody {
		return s
	}
	cut := maxBody
	for cut > 0 && !utf8.RuneStart(s[cut]) {
		cut--
	}
	return s[:cut]
}

const maxDisplayName = 128

func cleanName(s string) string {
	s = strings.TrimSpace(cleanText(s))
	if len(s) > maxDisplayName {
		cut := maxDisplayName
		for cut > 0 && !utf8.RuneStart(s[cut]) {
			cut--
		}
		s = s[:cut]
	}
	return s
}

// installPeerLocked files p as live or pending under its id and returns
// the connection to close once unlocked: the one p replaces, or p
// itself. When both sides dial at once each ends up holding two
// connections, so both keep the one dialed by the smaller identity key.
func (m *Manager) installPeerLocked(p *peer, pending bool) (drop *peer) {
	set := m.peers
	if pending {
		set = m.pending
	}
	old := set[p.id]
	if !pending && old != nil && old.outgoing != p.outgoing && m.dialerLocked(old) < m.dialerLocked(p) {
		if p.outgoing && old.token == "" {
			old.token = p.token
		}
		return p
	}
	set[p.id] = p
	return old
}

func (m *Manager) dialerLocked(p *peer) string {
	if p.outgoing {
		return m.selfID
	}
	return p.id
}

// unlinkLocked removes id from both sets, returning what was there.
func (m *Manager) unlinkLocked(id string) (live, pend *peer) {
	live, pend = m.peers[id], m.pending[id]
	delete(m.peers, id)
	delete(m.pending, id)
	return live, pend
}

// dropPeer closes a peer already unlinked from the sets and announces
// it: a live conversation ends, a pending request goes away.
func (m *Manager) dropPeer(p *peer, live bool) {
	p.close()
	if live {
		m.emit(map[string]any{"type": "peer-removed", "peer": p.id})
	} else {
		m.emit(map[string]any{"type": "peer-request-gone", "peer": p.id})
	}
}

// fingerprint is the pair's safety number: the same 20 digits on both
// sides, from both identity keys in a fixed order.
func fingerprint(a, b string) string {
	var ka, kb key.NodePublic
	if ka.UnmarshalText([]byte(a)) != nil || kb.UnmarshalText([]byte(b)) != nil {
		return ""
	}
	ra, rb := ka.Raw32(), kb.Raw32()
	if bytes.Compare(ra[:], rb[:]) > 0 {
		ra, rb = rb, ra
	}
	sum := sha256.Sum256(append(append([]byte("tincan safety number\x00"), ra[:]...), rb[:]...))
	groups := make([]string, 5)
	for i := range groups {
		groups[i] = fmt.Sprintf("%04d", binary.BigEndian.Uint32(sum[4*i:])%10000)
	}
	return strings.Join(groups, " ")
}

func (m *Manager) peerAddedEvent(p *peer) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{
		"type":          "peer-added",
		"peer":          p.id,
		"name":          p.name,
		"token":         p.token,
		"remotePending": p.remotePending,
		"fp":            fingerprint(m.selfID, p.id),
		"verified":      m.verified[p.id],
	}
}

func (m *Manager) peerRequestEvent(p *peer) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	first := ""
	if len(p.pendingTexts) > 0 {
		first = p.pendingTexts[0].Body
	}
	return map[string]any{
		"type": "peer-request", "peer": p.id, "name": p.name,
		"fp": fingerprint(m.selfID, p.id), "verified": m.verified[p.id], "first": first,
	}
}

func messageEvent(p *peer, msg *wireMsg) map[string]any {
	ev := map[string]any{"type": "message", "peer": p.id, "id": msg.ID, "ts": msg.TS, "body": msg.Body}
	if msg.Reply != "" {
		ev["reply"] = msg.Reply
	}
	return ev
}

// addPeer makes p the live connection to its peer, reporting false if
// the tie-break kept an existing one instead; p is closed then.
func (m *Manager) addPeer(p *peer) bool {
	m.mu.Lock()
	drop := m.installPeerLocked(p, false)
	live := m.peers[p.id]
	m.mu.Unlock()
	drop.close()
	m.noteInstance(live)
	if drop == p {
		// A kept connection gone stale fails on this rather than at the
		// read deadline.
		go live.writeMsg(&wireMsg{T: "ka"})
	}
	m.emit(m.peerAddedEvent(live))
	return drop != p
}

func (m *Manager) removePeer(p *peer) {
	m.mu.Lock()
	wasPending := m.pending[p.id] == p
	wasLive := m.peers[p.id] == p
	if wasPending {
		delete(m.pending, p.id)
	}
	if wasLive {
		delete(m.peers, p.id)
	}
	m.mu.Unlock()
	if wasPending || wasLive {
		m.dropPeer(p, wasLive)
	} else {
		p.close()
	}
}

func (m *Manager) peerByID(id string) (*peer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p := m.peers[id]
	if p == nil {
		return nil, fmt.Errorf("no connected peer %v", id)
	}
	return p, nil
}

const writeTimeout = 30 * time.Second

// write runs f with the connection to itself and a deadline, so a peer
// that stops reading can't pile up writers; a failed write ends the
// connection, which the read loop reports.
func (p *peer) write(f func() error) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	if p.onlyDirect != nil && p.onlyDirect.Load() && !p.direct.Load() {
		p.conn.Close()
		return errNoDirect
	}
	p.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
	err := f()
	if err != nil {
		p.conn.Close()
	}
	return err
}

func (p *peer) writeMsg(msg *wireMsg) error {
	return p.write(func() error { return writeMsgFrame(p.conn, msg) })
}

func (p *peer) writeEncoded(msg []byte) error {
	return p.write(func() error { return writeFrame(p.conn, frameMsg, msg) })
}

func (p *peer) writeBlob(id string, chunk []byte) error {
	return p.write(func() error { return writeBlobFrame(p.conn, id, chunk) })
}

// peerFor is a live, accepted peer that speaks feature.
func (m *Manager) peerFor(peerID, feature string) (*peer, error) {
	p, err := m.peerByID(peerID)
	if err == nil && !p.has(feature) {
		err = errors.New("their app is too old for this; ask them to update")
	}
	return p, err
}

// SendText sends one message, quoting replyTo when set. The peer acks
// it with a delivered event once stored.
func (m *Manager) SendText(peerID, id, body, replyTo string) error {
	if len(body) > maxBody {
		return fmt.Errorf("message too long: %d bytes, limit %d", len(body), maxBody)
	}
	p, err := m.peerByID(peerID)
	if err != nil {
		return err
	}
	return p.writeMsg(&wireMsg{T: "text", ID: id, TS: time.Now().UnixMilli(), Body: body, Reply: replyTo})
}

// SendReaction sets our reaction to message ref; an empty emoji
// removes it.
func (m *Manager) SendReaction(peerID, id, ref, emoji string) error {
	if len(emoji) > maxBody {
		return errors.New("reaction too long")
	}
	p, err := m.peerFor(peerID, "react")
	if err != nil {
		return err
	}
	return p.writeMsg(&wireMsg{T: "react", ID: id, Ref: ref, Body: emoji})
}

// SendTimer sets the chat's disappearing-message timer; 0 is off.
func (m *Manager) SendTimer(peerID, id string, seconds int) error {
	if seconds < 0 {
		return errors.New("negative timer")
	}
	p, err := m.peerFor(peerID, "timer")
	if err != nil {
		return err
	}
	return p.writeMsg(&wireMsg{T: "timer", ID: id, Body: strconv.Itoa(seconds)})
}

// SetActivePeer marks the chat on screen, whose path is measured every
// few seconds; "" for none.
func (m *Manager) SetActivePeer(peerID string) {
	m.mu.Lock()
	m.active = peerID
	m.mu.Unlock()
}

func (m *Manager) readLoop(p *peer) {
	defer m.abortRecvs(p)
	for {
		m.mu.Lock()
		limit := uint32(maxFrame)
		if m.pending[p.id] == p {
			limit = maxPendingFrame
		}
		m.mu.Unlock()
		p.conn.SetReadDeadline(time.Now().Add(readIdleLimit))
		kind, payload, err := readFrame(p.conn, limit)
		if err != nil {
			m.logf("tincan: connection to %v ended: %v", p.id, err)
			m.removePeer(p)
			return
		}
		switch kind {
		case frameMsg:
			msg, err := parseMsg(payload)
			if err != nil {
				m.logf("tincan: bad frame from %v: %v", p.id, err)
				m.removePeer(p)
				return
			}
			m.handleMsg(p, msg)
		case frameBlob:
			id, chunk, err := splitBlob(payload)
			if err != nil {
				m.logf("tincan: bad blob from %v: %v", p.id, err)
				m.removePeer(p)
				return
			}
			m.handleChunk(p, id, chunk)
		}
	}
}

// holdIfPending parks what a not-yet-accepted peer sends, reporting
// whether msg was consumed. Texts and the profile wait for Accept;
// everything else is dropped.
func (m *Manager) holdIfPending(p *peer, msg *wireMsg) bool {
	m.mu.Lock()
	if m.pending[p.id] != p {
		m.mu.Unlock()
		return false
	}
	first := false
	switch msg.T {
	case "text":
		if len(msg.Body) <= maxBody && len(p.pendingTexts) < maxPendingTexts {
			p.pendingTexts = append(p.pendingTexts, msg)
			first = len(p.pendingTexts) == 1
		}
	case "profile":
		// Strangers don't get to publish a picture into our UI, nor park
		// a big one in memory.
		if len(msg.Avatar) > maxAvatarBytes || len(msg.Avatar) > 0 && checkAvatar(msg.Avatar) != nil {
			msg.Avatar = nil
		}
		p.pendingProfile = msg
	}
	// Everything else waits for Accept; "accepted" would otherwise send
	// our profile to someone we never accepted.
	m.mu.Unlock()
	if first {
		m.emit(m.peerRequestEvent(p)) // now with what they said
	}
	return true
}

func (m *Manager) handleMsg(p *peer, msg *wireMsg) {
	if msg.T == "error" {
		msg.Body = capBody(cleanText(msg.Body))
		m.peerError(p.id, msg)
		return
	}
	if msg.T == "status" {
		m.notePath(p, msg)
		return
	}
	if m.holdIfPending(p, msg) {
		return
	}
	switch msg.T {
	case "text":
		if len(msg.Body) > maxBody {
			m.logf("tincan: oversized text from %v", p.id)
			return
		}
		m.emit(messageEvent(p, msg))
		p.writeMsg(&wireMsg{T: "ack", Ref: msg.ID})
	case "react":
		if len(msg.Body) > maxBody {
			return
		}
		m.emit(map[string]any{"type": "react", "peer": p.id, "id": msg.ID, "ref": msg.Ref, "body": msg.Body})
		p.writeMsg(&wireMsg{T: "ack", Ref: msg.ID})
	case "timer":
		secs, err := strconv.Atoi(msg.Body)
		if err != nil || secs < 0 {
			m.logf("tincan: bad timer %q from %v", msg.Body, p.id)
			return
		}
		m.emit(map[string]any{"type": "peer-timer", "peer": p.id, "id": msg.ID, "seconds": secs})
		p.writeMsg(&wireMsg{T: "ack", Ref: msg.ID})
	case "ack":
		m.emit(map[string]any{"type": "delivered", "peer": p.id, "id": msg.Ref})
	case "file-offer":
		m.startRecv(p, msg)
	case "file-resume":
		m.handleResume(p, msg)
	case "file-end":
		m.finishRecv(p, msg.ID)
	case "ka":
		// Receiving it already reset the read deadline.
	case "profile":
		m.applyPeerProfile(p, msg)
	case "file-cancel":
		m.cancelled(p, msg.Ref)
	case "pending":
		m.mu.Lock()
		p.remotePending = true
		m.mu.Unlock()
		m.emit(map[string]any{"type": "peer-pending", "peer": p.id})
	case "accepted":
		m.mu.Lock()
		was := p.remotePending
		p.remotePending = false
		m.mu.Unlock()
		if was {
			m.emit(map[string]any{"type": "peer-accepted", "peer": p.id})
			// They ignored our profile while we were a stranger.
			go p.writeMsg(m.profileMsg())
		}
	default:
		m.logf("tincan: ignoring unknown message %q from %v", msg.T, p.id)
	}
}

// statusLoop disco-pings dialed peers, which both measures the path and
// drives the direct upgrade, then mirrors the result to them: the
// accepting side has no per-peer path report of its own. The chat on
// screen gets one every statusActive, the rest every statusIdle.
const (
	statusActive = 5 * time.Second
	statusIdle   = 30 * time.Second
)

func (m *Manager) statusLoop() {
	tick := time.NewTicker(statusActive)
	defer tick.Stop()
	for {
		select {
		case <-m.stop:
			return
		case <-tick.C:
		}
		m.mu.Lock()
		active := m.active
		m.mu.Unlock()
		now := time.Now()
		for _, p := range m.snapshotPeers(false) {
			if !p.outgoing || p.id != active && now.Sub(p.lastPing) < statusIdle-time.Second {
				continue
			}
			if !p.pingBusy.CompareAndSwap(false, true) {
				continue
			}
			p.lastPing = now
			go func(p *peer) {
				defer p.pingBusy.Store(false)
				ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
				defer cancel()
				res, err := m.probe(ctx, p.client)
				if err != nil {
					m.logf("tincan: disco ping %v: %v", p.id, err)
					return
				}
				st := pathStatus(res)
				if m.notePath(p, st) {
					p.writeMsg(st)
				}
			}(p)
		}
	}
}

// applyPeerProfile stores a peer's profile. Profiles travel whole and
// repeat often; storeAvatar skips a picture already on disk. A picture
// that isn't a sane image counts as none.
func (m *Manager) applyPeerProfile(p *peer, msg *wireMsg) {
	avatar := msg.Avatar
	if len(avatar) > maxAvatarBytes || len(avatar) > 0 && checkAvatar(avatar) != nil {
		m.logf("tincan: unusable avatar from %v", p.id)
		avatar = nil
	}
	avatarPath, err := m.cfg.Vault.storeAvatar(p.id, avatar)
	if err != nil {
		m.logf("tincan: writing avatar: %v", err)
	}
	name := cleanName(msg.Name)

	m.mu.Lock()
	save := false
	if name != "" {
		p.name = name
		if old, ok := m.accepted[p.id]; ok && old != name {
			m.accepted[p.id] = name
			save = true
		}
	}
	if p.token == "" && ownToken(msg.SelfAddr, p.id) {
		// Lets us redial a peer that dialed us.
		p.token = msg.SelfAddr
	}
	token := p.token
	m.mu.Unlock()
	if save {
		m.saveRoster()
	}
	m.emit(map[string]any{
		"type": "peer-profile", "peer": p.id,
		"name": name, "description": capBody(cleanText(msg.Desc)), "status": capBody(cleanText(msg.Status)),
		"avatarPath": avatarPath, "token": token,
	})
}

// Two devices running one identity both stay online and keep replacing
// each other's connection here. A restarted app also brings a new
// instance id, but the old one never comes back, so only an instance
// that returns after another replaced it counts. Both are then told,
// on every connection within dupeFor, and warn their user.
const (
	instWindow = 3 * time.Minute
	dupeFor    = 10 * time.Minute
)

type dupe struct {
	insts map[string]bool
	at    time.Time
}

func (m *Manager) noteInstance(p *peer) {
	if p == nil || p.inst == "" {
		return
	}
	now := time.Now()
	m.mu.Lock()
	seen := m.insts[p.id]
	if seen == nil {
		seen = make(map[string]time.Time)
		mapSet(&m.insts, p.id, seen)
	}
	for inst, t := range seen {
		if now.Sub(t) > instWindow {
			delete(seen, inst)
		}
	}
	_, returning := seen[p.inst]
	if returning && m.lastInst[p.id] != p.inst {
		d := dupe{insts: make(map[string]bool), at: now}
		for inst := range seen {
			d.insts[inst] = true
		}
		mapSet(&m.dupes, p.id, d)
	}
	seen[p.inst] = now
	mapSet(&m.lastInst, p.id, p.inst)
	d, flagged := m.dupes[p.id]
	tell := flagged && now.Sub(d.at) < dupeFor && d.insts[p.inst]
	m.mu.Unlock()
	if tell && p.toldDupe.CompareAndSwap(false, true) {
		body := "another device is using this identity"
		go p.writeMsg(&wireMsg{T: "error", Code: "duplicate-identity", Body: body})
		m.emit(map[string]any{"type": "peer-error", "peer": p.id, "code": "duplicate-identity", "body": "this contact is running on two devices at once"})
	}
}

// Disconnect drops a peer without blocking them; they stay accepted, so
// either side can reconnect without a new request.
func (m *Manager) Disconnect(peerID string) error {
	m.mu.Lock()
	live, pend := m.unlinkLocked(peerID)
	m.mu.Unlock()
	// Nothing connected is fine: the caller still drops its copy.
	if live != nil {
		m.dropPeer(live, true)
	}
	if pend != nil {
		m.dropPeer(pend, false)
	}
	return nil
}

// Resync re-emits the peers for a UI that restarted (Android recreates
// the activity) and missed everything so far; Started covers the rest.
func (m *Manager) Resync() {
	for _, p := range m.snapshotPeers(false) {
		m.emit(m.peerAddedEvent(p))
	}
	m.mu.Lock()
	pend := slices.Collect(maps.Values(m.pending))
	m.mu.Unlock()
	for _, p := range pend {
		m.emit(m.peerRequestEvent(p))
	}
}
