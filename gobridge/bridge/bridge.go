// Package bridge implements tincan's chat layer over the tailcat
// transport. Each app runs a tailcat server (its address is the user's
// identity) and dials peers as a client; one TCP stream per peer
// carries CBOR messages and file chunks (proto.go). Everything is
// reported as JSON events, so FFI callers stay language-agnostic.
package bridge

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/tailscale/tailcat"
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
	// It wins over DERPMapURL, which serves a whole map of them.
	DERPHost   string
	DERPMapURL string

	// Vault encrypts everything written under StateDir and DownloadDir.
	// Required: the bridge does not write plaintext.
	Vault *Vault

	Logf logger.Logf // nil means discard
}

type Manager struct {
	cfg    Config
	logf   logger.Logf
	events chan string

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
	rosterSeq  uint64 // bumped per roster snapshot

	saveMu      sync.Mutex // orders roster writes
	rosterSaved uint64

	stop      chan struct{}
	closeOnce sync.Once
}

type peer struct {
	id       string // stable identity: peer's server node key string
	name     string
	token    string // set on outgoing peers; how to reach them again
	outgoing bool

	conn    net.Conn
	client  *tailcat.Client // outgoing only
	writeMu sync.Mutex

	// Buffered while awaiting acceptance, replayed on Accept. Manager.mu.
	pendingTexts []*wireMsg

	// Applied on Accept. Manager.mu.
	pendingProfile *wireMsg

	// Outgoing peers: the far side hasn't accepted us yet. Manager.mu.
	remotePending bool

	recvMu sync.Mutex
	recv   map[string]*recvFile
}

func (p *peer) close() {
	if p == nil {
		return
	}
	p.conn.Close()
	if p.client != nil {
		p.client.Close()
	}
}

const maxPendingTexts = 25

type recvFile struct {
	f     *os.File
	w     io.Writer // sealing wrapper around f
	final string
	name  string
	kind  string
	size  int64
	got   int64
	prog  progress
}

// progress throttles file-progress events to whole-percent steps, or
// one per progressEvery when the percent moves slower than that.
type progress struct {
	pct  int64
	last time.Time
}

const progressEvery = 150 * time.Millisecond

func (pr *progress) due(done, size int64) bool {
	pct := int64(-1)
	if size > 0 {
		pct = done * 100 / size
	}
	now := time.Now()
	if pct == pr.pct && now.Sub(pr.last) < progressEvery {
		return false
	}
	pr.pct, pr.last = pct, now
	return true
}

func New(cfg Config) *Manager {
	logf := cfg.Logf
	if logf == nil {
		logf = logger.Discard
	}
	return &Manager{
		cfg:     cfg,
		logf:    logf,
		name:    cfg.Name,
		events:  make(chan string, 1024),
		peers:   make(map[string]*peer),
		pending: make(map[string]*peer),
		stop:    make(chan struct{}),
	}
}

// NextEventTimeout yields one JSON object per event, each with a
// "type", waiting up to d or until cancel closes. FFI callers poll
// rather than block forever: a thread parked in native code wedges the
// host VM's shutdown.
func (m *Manager) NextEventTimeout(d time.Duration, cancel <-chan struct{}) (ev string, ok bool) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case ev = <-m.events:
		return ev, true
	case <-t.C:
	case <-cancel:
	}
	return "", false
}

func (m *Manager) emit(ev map[string]any) {
	j, err := json.Marshal(ev)
	if err != nil {
		return
	}
	select {
	case m.events <- string(j):
	default:
		m.logf("tincan: event queue full, dropping %s", ev["type"])
	}
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
	if err := m.loadRoster(); err != nil {
		return err
	}
	m.loadProfile()
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
			go func(p *peer) {
				if err := p.writeMsg(&wireMsg{T: "ka"}); err != nil {
					p.conn.Close() // unblocks the read loop, which reports it
				}
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

// loadProfile restores the profile from the vault, at startup and when
// a restored account replaces it.
func (m *Manager) loadProfile() {
	var sp storedProfile
	if m.loadJSON(profileFile, &sp) != nil || sp.Name == "" {
		sp = storedProfile{Name: m.cfg.Name}
	}
	var avatar []byte
	path := m.cfg.Vault.selfAvatar()
	if path != "" {
		avatar, _ = m.cfg.Vault.ReadMedia(path)
	}
	if len(avatar) == 0 {
		path = ""
	}
	m.mu.Lock()
	m.name, m.desc, m.status = sp.Name, sp.Desc, sp.Status
	m.avatar, m.avatarPath = avatar, path
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
// restore-account path, once the caller has written the files.
func (m *Manager) Restart() (map[string]any, error) {
	m.lifeMu.Lock()
	defer m.lifeMu.Unlock()
	m.mu.Lock()
	m.accepted = nil
	m.blocked = nil
	m.mu.Unlock()
	pk, _, err := m.loadIdentity()
	if err != nil {
		return nil, err
	}
	if err := m.loadRoster(); err != nil {
		return nil, err
	}
	m.loadProfile()
	srv, err := m.newServer(pk)
	if err != nil {
		// The old account is gone; retry as the restored one.
		m.teardown()
		m.mu.Lock()
		m.priv = pk
		m.mu.Unlock()
		m.downLocked(err)
		return nil, fmt.Errorf("restarting: %w", err)
	}
	return m.replaceServer(srv, pk), nil
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

// SetDERP switches the relay the server listens on. The key is kept,
// but the address embeds the relay, so it changes and old copies of it
// stop working. If a running server's replacement fails, the previous
// relay stays in use. With no server running there is nothing to keep:
// the new relay stays, starting is retried on it, and the result is
// empty, as the server-started event comes later.
func (m *Manager) SetDERP(host, mapURL string) (map[string]any, error) {
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
		T:       "hello",
		V:       protoVersion,
		Name:    m.name,
		Key:     m.selfID,
		ConnKey: connKey,
		Proof:   proof,
	}
}

// helloProof is what a dialer seals from its identity key to the
// server's: anyone can claim a key in a hello, only its owner can seal.
func helloProof(connKey string) []byte { return []byte("tincan hello v1 " + connKey) }

// verifyHello checks an incoming hello's proof and returns its key in
// canonical form, so a re-spelled key can't dodge the block list.
func (m *Manager) verifyHello(h *wireMsg) (string, error) {
	var pub key.NodePublic
	if err := pub.UnmarshalText([]byte(h.Key)); err != nil || pub.IsZero() {
		return "", fmt.Errorf("bad identity key %q", h.Key)
	}
	plain, ok := m.identityKey().OpenFrom(pub, h.Proof)
	if !ok || string(plain) != string(helloProof(h.ConnKey)) {
		return "", fmt.Errorf("hello from %v carries no valid proof of its key", pub.ShortString())
	}
	return pub.String(), nil
}

// Connect dials a peer in the background and returns their id at once.
// The outcome arrives as peer-added or connect-error; reaching someone
// offline takes up to 45s to fail.
func (m *Manager) Connect(token string) (peerID string, err error) {
	server, err := m.dialTarget(token)
	if err != nil {
		return "", err
	}
	go func() {
		if _, err := m.dial(token, server); err != nil {
			m.emit(map[string]any{"type": "connect-error", "peer": server.String(), "error": err.Error()})
		}
	}()
	return server.String(), nil
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

	conn, err := cl.DialTCPPort(ctx, ChatPort)
	if err != nil {
		cl.Close()
		return "", fmt.Errorf("dialing peer: %w", err)
	}

	conn.SetDeadline(time.Now().Add(20 * time.Second))
	connKey := cl.PublicKey().String()
	if err := writeMsgFrame(conn, m.hello(connKey, m.identityKey().SealTo(server, helloProof(connKey)))); err != nil {
		conn.Close()
		cl.Close()
		return "", fmt.Errorf("sending hello: %w", err)
	}
	theirs, err := readHello(conn)
	if err == nil && theirs.Key != server.String() {
		// WireGuard proved who answered; the hello's key must agree.
		err = fmt.Errorf("peer claims key %q, not the address's", theirs.Key)
	}
	if err != nil {
		conn.Close()
		cl.Close()
		return "", fmt.Errorf("reading hello: %w", err)
	}
	conn.SetDeadline(time.Time{})

	p := &peer{
		id:       theirs.Key,
		name:     theirs.Name,
		token:    token,
		outgoing: true,
		conn:     conn,
		client:   cl,
		recv:     make(map[string]*recvFile),
	}
	// Dialing someone is implicit acceptance of them.
	m.mu.Lock()
	mapSet(&m.accepted, p.id, p.name)
	roster := m.rosterLocked()
	m.mu.Unlock()
	m.saveRoster(roster)
	if m.addPeer(p) {
		go m.readLoop(p)
		go p.writeMsg(m.profileMsg())
	}
	return p.id, nil
}

func (m *Manager) handleIncoming(conn net.Conn) {
	conn.SetDeadline(time.Now().Add(20 * time.Second))
	theirs, err := readHello(conn)
	if err == nil {
		theirs.Key, err = m.verifyHello(theirs)
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

	if err := writeMsgFrame(conn, m.hello("", nil)); err != nil {
		conn.Close()
		return
	}
	conn.SetDeadline(time.Time{})

	p := &peer{
		id:   theirs.Key,
		name: theirs.Name,
		conn: conn,
		recv: make(map[string]*recvFile),
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
		m.mu.Lock()
		full := len(m.pending) >= maxPendingPeers && m.pending[p.id] == nil
		m.mu.Unlock()
		if full {
			// Fresh keys are free, so requests are cheap to spam.
			conn.Close()
			return
		}
		if err := p.writeMsg(&wireMsg{T: "pending"}); err != nil {
			conn.Close()
			return
		}
		m.mu.Lock()
		old := m.installPeerLocked(p, true)
		m.mu.Unlock()
		old.close()
		m.emit(m.peerRequestEvent(p))
	}
	m.readLoop(p) // handleIncoming runs on its own goroutine already
}

const maxPendingPeers = 64

func readHello(conn net.Conn) (*wireMsg, error) {
	kind, payload, err := readFrame(conn)
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
	if msg.T != "hello" {
		return nil, fmt.Errorf("first message is %q, not hello", msg.T)
	}
	if msg.V != protoVersion {
		return nil, fmt.Errorf("peer speaks protocol v%d, we speak v%d", msg.V, protoVersion)
	}
	if msg.Key == "" {
		return nil, errors.New("hello lacks an identity key")
	}
	return msg, nil
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

func (m *Manager) peerAddedEvent(p *peer) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{
		"type":          "peer-added",
		"peer":          p.id,
		"name":          p.name,
		"token":         p.token,
		"remotePending": p.remotePending,
	}
}

func (m *Manager) peerRequestEvent(p *peer) map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{"type": "peer-request", "peer": p.id, "name": p.name}
}

func messageEvent(p *peer, msg *wireMsg) map[string]any {
	return map[string]any{"type": "message", "peer": p.id, "id": msg.ID, "ts": msg.TS, "body": msg.Body}
}

// addPeer makes p the live connection to its peer, reporting false if
// the tie-break kept an existing one instead; p is closed then.
func (m *Manager) addPeer(p *peer) bool {
	m.mu.Lock()
	drop := m.installPeerLocked(p, false)
	live := m.peers[p.id]
	m.mu.Unlock()
	drop.close()
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

func (p *peer) writeMsg(msg *wireMsg) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return writeMsgFrame(p.conn, msg)
}

func (p *peer) writeEncoded(msg []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return writeFrame(p.conn, frameMsg, msg)
}

func (p *peer) writeBlob(id string, chunk []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return writeBlobFrame(p.conn, id, chunk)
}

// SendText sends one message. id is echoed in failure events.
func (m *Manager) SendText(peerID, id, body string) error {
	p, err := m.peerByID(peerID)
	if err != nil {
		return err
	}
	return p.writeMsg(&wireMsg{T: "text", ID: id, TS: time.Now().UnixMilli(), Body: body})
}

func MediaKind(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".bmp":
		return "image"
	case ".mp4", ".mov", ".mkv", ".webm", ".avi", ".m4v":
		return "video"
	}
	return "file"
}

// SentFile is what SendFile reports about a file it is sending.
type SentFile struct {
	Name string
	Kind string
	Size int64
	Path string // the sealed copy in DownloadDir
}

// SendFile streams a file, sealing a copy into DownloadDir as it goes,
// so the message refers to the app's own copy. A path already under
// DownloadDir is such a copy, sent again. The copy is kept even when
// sending fails, so it can be retried; progress and the outcome arrive
// as events.
func (m *Manager) SendFile(peerID, id, path string) (SentFile, error) {
	src, size, err := m.openSource(path)
	if err != nil {
		return SentFile{}, err
	}
	sf := SentFile{Name: filepath.Base(path), Kind: MediaKind(path), Size: size, Path: path}
	var out *os.File
	if !m.sealed(path) {
		if out, sf.Path, err = createUnique(m.cfg.DownloadDir, sf.Name); err != nil {
			src.Close()
			return SentFile{}, err
		}
	}
	p, err := m.peerByID(peerID)
	if err == nil {
		m.mu.Lock()
		if p.remotePending {
			err = errors.New("waiting for the peer to accept your request; files can't be sent yet")
		}
		m.mu.Unlock()
	}
	go m.streamFile(peerID, p, err, id, sf, src, out)
	return sf, nil
}

func (m *Manager) sealed(path string) bool {
	rel, err := filepath.Rel(m.cfg.DownloadDir, path)
	return err == nil && filepath.IsLocal(rel)
}

// openSource opens a file to send as plaintext, with its size.
func (m *Manager) openSource(path string) (io.ReadCloser, int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, 0, err
	}
	if m.sealed(path) {
		size, err := m.cfg.Vault.MediaSize(path)
		if err != nil {
			f.Close()
			return nil, 0, err
		}
		return struct {
			io.Reader
			io.Closer
		}{m.cfg.Vault.ChunkReader(f), f}, size, nil
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, 0, err
	}
	return f, fi.Size(), nil
}

// streamFile sends src to p, unless sendErr says p is unusable, while
// sealing it into out when that is set.
func (m *Manager) streamFile(peerID string, p *peer, sendErr error, id string, sf SentFile, src io.ReadCloser, out *os.File) {
	defer src.Close()
	fail := func(err error) {
		m.emit(map[string]any{"type": "send-error", "peer": peerID, "id": id, "error": err.Error()})
	}
	var seal io.Writer
	if out != nil {
		seal = m.cfg.Vault.ChunkWriter(out)
	}
	if sendErr == nil {
		sendErr = p.writeMsg(&wireMsg{T: "file", ID: id, TS: time.Now().UnixMilli(), File: sf.Name, Size: sf.Size, Kind: sf.Kind})
	}
	buf := make([]byte, chunkSize)
	var sent int64
	var prog progress
	for seal != nil || sendErr == nil {
		n, rerr := io.ReadFull(src, buf)
		if n > 0 && seal != nil {
			if _, err := seal.Write(buf[:n]); err != nil {
				rerr = err
			}
		}
		if n > 0 && sendErr == nil {
			if sendErr = p.writeBlob(id, buf[:n]); sendErr == nil {
				sent += int64(n)
				if prog.due(sent, sf.Size) {
					m.emit(map[string]any{"type": "file-progress", "peer": peerID, "id": id, "done": sent, "size": sf.Size})
				}
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			break
		}
		if rerr != nil {
			if out != nil {
				out.Close()
				os.Remove(sf.Path + ".part")
			}
			fail(rerr)
			return
		}
	}
	if out != nil {
		if err := commitPart(out, sf.Path); err != nil && sendErr == nil {
			sendErr = err
		}
	}
	if sendErr == nil {
		sendErr = p.writeMsg(&wireMsg{T: "file-end", ID: id})
	}
	if sendErr != nil {
		fail(sendErr)
		return
	}
	m.emit(map[string]any{"type": "file-done", "peer": peerID, "id": id, "path": sf.Path, "name": sf.Name, "size": sf.Size})
}

func (m *Manager) readLoop(p *peer) {
	defer m.abortRecvs(p)
	for {
		p.conn.SetReadDeadline(time.Now().Add(readIdleLimit))
		kind, payload, err := readFrame(p.conn)
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
// files and path reports are dropped.
func (m *Manager) holdIfPending(p *peer, msg *wireMsg) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.pending[p.id] != p {
		return false
	}
	switch msg.T {
	case "text":
		if len(p.pendingTexts) < maxPendingTexts {
			p.pendingTexts = append(p.pendingTexts, msg)
		}
	case "profile":
		// Strangers don't get to publish a picture into our UI.
		p.pendingProfile = msg
	}
	// Everything else waits for Accept; "accepted" would otherwise send
	// our profile to someone we never accepted.
	return true
}

func (m *Manager) handleMsg(p *peer, msg *wireMsg) {
	if m.holdIfPending(p, msg) {
		return
	}
	switch msg.T {
	case "text":
		m.emit(messageEvent(p, msg))
	case "file":
		m.startRecv(p, msg)
	case "file-end":
		m.finishRecv(p, msg.ID)
	case "ka":
		// Receiving it already reset the read deadline.
	case "profile":
		m.applyPeerProfile(p, msg)
	case "status":
		m.emit(map[string]any{
			"type": "peer-status", "peer": p.id,
			"direct": msg.Direct, "addr": msg.Addr, "relay": msg.Relay,
			"latencyMs": msg.Ms,
		})
	case "pending":
		m.mu.Lock()
		p.remotePending = true
		m.mu.Unlock()
		m.emit(map[string]any{"type": "peer-pending", "peer": p.id})
	case "accepted":
		m.mu.Lock()
		p.remotePending = false
		m.mu.Unlock()
		m.emit(map[string]any{"type": "peer-accepted", "peer": p.id})
		// They ignored our profile while we were a stranger.
		go p.writeMsg(m.profileMsg())
	default:
		m.logf("tincan: ignoring unknown message %q from %v", msg.T, p.id)
	}
}

// sanitizeName reduces a peer-supplied filename to a safe base name.
func sanitizeName(name string) string {
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	name = strings.TrimLeft(name, ".")
	if name == "" {
		name = "file"
	}
	return name
}

const maxNameBytes = 200

// capName keeps room under the filesystem's 255-byte limit for the
// " (n)" and ".part" that uniquePath and createUnique add.
func capName(name string) string {
	if len(name) <= maxNameBytes {
		return name
	}
	ext := filepath.Ext(name)
	if len(ext) > 16 {
		ext = ""
	}
	cut := maxNameBytes - len(ext)
	for cut > 0 && !utf8.RuneStart(name[cut]) {
		cut--
	}
	return name[:cut] + ext
}

// uniquePath returns dir/name, or dir/name (2) etc if taken. A path it
// can't check counts as free, so opening it reports why.
func uniquePath(dir, name string) string {
	taken := func(path string) bool {
		_, err := os.Lstat(path)
		return err == nil
	}
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	path := filepath.Join(dir, name)
	for i := 2; taken(path) || taken(path+".part"); i++ {
		path = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", stem, i, ext))
	}
	return path
}

func (m *Manager) startRecv(p *peer, msg *wireMsg) {
	name := sanitizeName(msg.File)
	f, final, err := createUnique(m.cfg.DownloadDir, name)
	if err != nil {
		m.logf("tincan: recv %q: %v", name, err)
		return
	}
	rf := &recvFile{
		f: f, w: m.cfg.Vault.ChunkWriter(f),
		final: final, name: filepath.Base(final), kind: MediaKind(name), size: msg.Size,
	}
	p.recvMu.Lock()
	dup := p.recv[msg.ID]
	p.recv[msg.ID] = rf
	p.recvMu.Unlock()
	if dup != nil {
		dup.discard()
	}
	m.emit(map[string]any{"type": "file-begin", "peer": p.id, "id": msg.ID, "ts": msg.TS, "name": rf.name, "size": msg.Size, "kind": rf.kind})
}

func (rf *recvFile) discard() {
	rf.f.Close()
	os.Remove(rf.final + ".part")
}

// abortRecvs drops the transfers a closed connection left unfinished.
func (m *Manager) abortRecvs(p *peer) {
	p.recvMu.Lock()
	recv := p.recv
	p.recv = make(map[string]*recvFile)
	p.recvMu.Unlock()
	for id, rf := range recv {
		rf.discard()
		m.emit(map[string]any{"type": "recv-error", "peer": p.id, "id": id})
	}
}

func (m *Manager) handleChunk(p *peer, id string, chunk []byte) {
	p.recvMu.Lock()
	rf := p.recv[id]
	p.recvMu.Unlock()
	if rf == nil {
		return // unknown transfer; drop
	}
	if _, err := rf.w.Write(chunk); err != nil {
		m.logf("tincan: writing %q: %v", rf.final, err)
		return
	}
	rf.got += int64(len(chunk))
	if rf.prog.due(rf.got, rf.size) {
		m.emit(map[string]any{"type": "file-progress", "peer": p.id, "id": id, "done": rf.got, "size": rf.size})
	}
}

func (m *Manager) finishRecv(p *peer, id string) {
	p.recvMu.Lock()
	rf := p.recv[id]
	delete(p.recv, id)
	p.recvMu.Unlock()
	if rf == nil {
		return
	}
	if err := commitPart(rf.f, rf.final); err != nil {
		m.logf("tincan: finishing %q: %v", rf.final, err)
		m.emit(map[string]any{"type": "recv-error", "peer": p.id, "id": id})
		return
	}
	m.emit(map[string]any{"type": "file-done", "peer": p.id, "id": id, "path": rf.final, "name": rf.name, "size": rf.got})
}

// statusLoop disco-pings each dialed peer, which both measures the path
// and drives the direct upgrade, then mirrors the result to them: the
// accepting side has no per-peer path report of its own.
func (m *Manager) statusLoop() {
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-m.stop:
			return
		case <-tick.C:
		}
		for _, p := range m.snapshotPeers(false) {
			if !p.outgoing {
				continue
			}
			go func(p *peer) {
				ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
				defer cancel()
				res, err := p.client.DiscoPing(ctx)
				if err != nil {
					m.logf("tincan: disco ping %v: %v", p.id, err)
					return
				}
				ms := int(res.LatencySeconds*1000 + 0.5)
				if ms < 1 {
					ms = 1
				}
				m.emit(map[string]any{
					"type": "peer-status", "peer": p.id,
					"direct":    res.Endpoint != "",
					"addr":      res.Endpoint,
					"relay":     res.DERPRegionCode,
					"latencyMs": ms,
				})
				p.writeMsg(&wireMsg{
					T:      "status",
					Direct: res.Endpoint != "",
					Addr:   res.Endpoint,
					Relay:  res.DERPRegionCode,
					Ms:     ms,
				})
			}(p)
		}
	}
}

// applyPeerProfile stores a peer's profile. Profiles travel whole and
// repeat often; storeAvatar skips a picture already on disk.
func (m *Manager) applyPeerProfile(p *peer, msg *wireMsg) {
	avatarPath := ""
	if len(msg.Avatar) > maxAvatarBytes {
		m.logf("tincan: oversized avatar from %v", p.id)
	} else {
		// No picture means they removed it.
		path, err := m.cfg.Vault.storeAvatar(p.id, msg.Avatar)
		if err != nil {
			m.logf("tincan: writing avatar: %v", err)
		}
		avatarPath = path
	}

	m.mu.Lock()
	var roster *rosterSnapshot
	if msg.Name != "" {
		p.name = msg.Name
		if old, ok := m.accepted[p.id]; ok && old != msg.Name {
			m.accepted[p.id] = msg.Name
			r := m.rosterLocked()
			roster = &r
		}
	}
	if msg.SelfAddr != "" && p.token == "" {
		// Lets us redial a peer that dialed us, if it is really theirs.
		if ci, err := tailcat.ParseConnBlob(tailcat.ConnBlob(msg.SelfAddr)); err == nil && ci.ServerPublic.String() == p.id {
			p.token = msg.SelfAddr
		}
	}
	token := p.token
	m.mu.Unlock()
	if roster != nil {
		m.saveRoster(*roster)
	}
	m.emit(map[string]any{
		"type": "peer-profile", "peer": p.id,
		"name": msg.Name, "description": msg.Desc, "status": msg.Status,
		"avatarPath": avatarPath, "token": token,
	})
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
