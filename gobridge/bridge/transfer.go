package bridge

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

// A file goes out as file-offer; the receiver answers file-resume with
// how much of it a kept .part already holds, the sender streams the
// rest as blob frames and ends with file-end, and the receiver acks once
// the whole file is in place. A dropped connection keeps the .part, so
// resending the same message id picks up where it stopped.

const (
	maxRecvsPerPeer = 4
	maxSendsPerPeer = 4
	offerTimeout    = time.Minute
	staleAfter      = 7 * 24 * time.Hour
	partialDir      = ".partial"
	freeMargin      = 32 << 20
)

type recvFile struct {
	mu    sync.Mutex
	owner *peer
	f     *os.File
	w     *ChunkWriter
	part  string
	name  string
	kind  string
	size  int64
	got   int64
	prog  progress
	dead  bool
}

// stop closes the file and leaves the .part for a resume.
func (rf *recvFile) stop() {
	rf.mu.Lock()
	defer rf.mu.Unlock()
	if !rf.dead {
		rf.dead = true
		rf.f.Close()
	}
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
// sending fails, so it can be retried with the same id, which resumes;
// progress and the outcome arrive as events.
func (m *Manager) SendFile(peerID, id, path string) (SentFile, error) {
	if id == "" || len(id) > transferIDLen {
		return SentFile{}, fmt.Errorf("transfer id must be 1 to %d bytes", transferIDLen)
	}
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
	sc := m.trackSend(peerID, id)
	go func() {
		defer m.untrackSend(peerID, id, sc)
		m.streamFile(peerID, p, err, id, sf, src, out, sc)
	}()
	return sf, nil
}

var errCancelled = errors.New("cancelled")

// sendCancel stops one outgoing transfer.
type sendCancel struct {
	ch    chan struct{}
	once  sync.Once
	quiet bool // the peer needn't hear of it; set before ch closes
}

func (sc *sendCancel) fire(quiet bool) {
	sc.once.Do(func() {
		sc.quiet = quiet
		close(sc.ch)
	})
}

func (sc *sendCancel) fired() bool {
	select {
	case <-sc.ch:
		return true
	default:
		return false
	}
}

func (m *Manager) trackSend(peerID, id string) *sendCancel {
	sc := &sendCancel{ch: make(chan struct{})}
	m.sendMu.Lock()
	defer m.sendMu.Unlock()
	if old := m.sends[transferKey(peerID, id)]; old != nil {
		old.fire(true) // a resend takes over
	}
	m.sends[transferKey(peerID, id)] = sc
	return sc
}

func (m *Manager) untrackSend(peerID, id string, sc *sendCancel) {
	m.sendMu.Lock()
	defer m.sendMu.Unlock()
	if m.sends[transferKey(peerID, id)] == sc {
		delete(m.sends, transferKey(peerID, id))
	}
}

func (m *Manager) sendFor(peerID, id string) *sendCancel {
	m.sendMu.Lock()
	defer m.sendMu.Unlock()
	return m.sends[transferKey(peerID, id)]
}

// CancelTransfer stops a file going either way and tells the peer, whose
// partial copy goes too. A sender keeps its sealed copy for a retry.
func (m *Manager) CancelTransfer(peerID, id string) error {
	if sc := m.sendFor(peerID, id); sc != nil {
		sc.fire(false) // the stream tells the peer, after its offer
		return nil
	}
	m.dropRecv(peerID, id)
	p, err := m.peerByID(peerID)
	if err != nil {
		return nil // the peer's partial ages out with sweepStale
	}
	return p.writeMsg(&wireMsg{T: "file-cancel", Ref: id})
}

// cancelled handles the peer's file-cancel, whichever way the file went.
func (m *Manager) cancelled(p *peer, id string) {
	if sc := m.sendFor(p.id, id); sc != nil {
		sc.fire(true)
	}
	m.dropRecv(p.id, id)
	m.emit(map[string]any{"type": "transfer-cancelled", "peer": p.id, "id": id})
}

// dropRecv stops a transfer from peerID and deletes what it kept.
func (m *Manager) dropRecv(peerID, id string) {
	key := transferKey(peerID, id)
	m.recvMu.Lock()
	rf := m.recvs[key]
	delete(m.recvs, key)
	m.recvMu.Unlock()
	if rf != nil {
		rf.stop()
	}
	os.Remove(m.partPath(key))
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
func (m *Manager) streamFile(peerID string, p *peer, sendErr error, id string, sf SentFile, src io.ReadCloser, out *os.File, sc *sendCancel) {
	defer src.Close()
	fail := func(err error) {
		m.emit(map[string]any{"type": "send-error", "peer": peerID, "id": id, "error": err.Error()})
	}
	var seal *ChunkWriter
	if out != nil {
		seal = m.cfg.Vault.ChunkWriter(out)
	}
	var have int64
	if sendErr == nil {
		select {
		case p.sendSlots <- struct{}{}:
			defer func() { <-p.sendSlots }()
			have, sendErr = m.offer(p, id, sf, sc.ch)
		case <-p.done:
			sendErr = errors.New("connection closed")
		case <-sc.ch:
			sendErr = errCancelled
		}
	}
	buf := make([]byte, chunkSize)
	var off int64
	var prog progress
	for seal != nil || sendErr == nil {
		n, rerr := io.ReadFull(src, buf)
		if n > 0 && seal != nil {
			if _, err := seal.Write(buf[:n]); err != nil {
				rerr = err
			}
		}
		if sendErr == nil && sc.fired() {
			sendErr = errCancelled
		}
		if end := off + int64(n); n > 0 && sendErr == nil && end > have {
			if sendErr = p.writeBlob(id, buf[max(0, have-off):n]); sendErr == nil && prog.due(end, sf.Size) {
				m.emit(map[string]any{"type": "file-progress", "peer": peerID, "id": id, "done": end, "size": sf.Size})
			}
		}
		off += int64(n)
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
		err := seal.Close()
		if err != nil {
			out.Close()
			os.Remove(sf.Path + ".part")
		} else {
			err = commitPart(out, sf.Path)
		}
		if err != nil && sendErr == nil {
			sendErr = err
		}
	}
	if sendErr == nil {
		sendErr = p.writeMsg(&wireMsg{T: "file-end", ID: id})
	}
	if errors.Is(sendErr, errCancelled) {
		if !sc.quiet && p != nil {
			p.writeMsg(&wireMsg{T: "file-cancel", Ref: id})
		}
		return
	}
	if sendErr != nil {
		fail(sendErr)
		return
	}
	m.emit(map[string]any{"type": "file-done", "peer": peerID, "id": id, "path": sf.Path, "name": sf.Name, "size": sf.Size})
}

// offer announces a file and returns how much of it the peer has.
func (m *Manager) offer(p *peer, id string, sf SentFile, cancel <-chan struct{}) (int64, error) {
	ch := make(chan int64, 1)
	p.offerMu.Lock()
	p.offers[id] = ch
	p.offerMu.Unlock()
	defer func() {
		p.offerMu.Lock()
		delete(p.offers, id)
		p.offerMu.Unlock()
	}()
	err := p.writeMsg(&wireMsg{T: "file-offer", ID: id, TS: time.Now().UnixMilli(), File: sf.Name, Size: sf.Size, Kind: sf.Kind})
	if err != nil {
		return 0, err
	}
	select {
	case have := <-ch:
		if have < 0 {
			return 0, errors.New("the peer can't take this file right now")
		}
		if have > sf.Size {
			return 0, fmt.Errorf("peer claims %d of %d bytes", have, sf.Size)
		}
		return have, nil
	case <-p.done:
		return 0, errors.New("connection closed")
	case <-cancel:
		return 0, errCancelled
	case <-time.After(offerTimeout):
		return 0, errors.New("the peer did not answer the file offer")
	}
}

func (m *Manager) handleResume(p *peer, msg *wireMsg) {
	p.offerMu.Lock()
	ch := p.offers[msg.Ref]
	p.offerMu.Unlock()
	if ch != nil {
		select {
		case ch <- msg.Have:
		default:
		}
	}
}

func recvKey(p *peer, id string) string { return transferKey(p.id, id) }

func transferKey(peerID, id string) string { return peerID + "\x00" + id }

// partPath is where a transfer from one peer under one id accumulates,
// the same across connections so it can resume.
func (m *Manager) partPath(key string) string {
	sum := sha256.Sum256([]byte(key))
	return filepath.Join(m.cfg.DownloadDir, partialDir, hex.EncodeToString(sum[:16])+".part")
}

func (m *Manager) startRecv(p *peer, msg *wireMsg) {
	refuse := func(err error) {
		m.logf("tincan: refusing file %q from %v: %v", msg.ID, p.id, err)
		m.emit(map[string]any{"type": "recv-error", "peer": p.id, "id": msg.ID, "error": err.Error()})
		p.writeMsg(&wireMsg{T: "file-resume", Ref: msg.ID, Have: -1})
	}
	if msg.ID == "" || len(msg.ID) > transferIDLen || msg.Size < 0 {
		refuse(errors.New("bad transfer id or size"))
		return
	}
	key := recvKey(p, msg.ID)
	m.recvMu.Lock()
	old := m.recvs[key]
	n := 0
	for _, rf := range m.recvs {
		if rf.owner == p {
			n++
		}
	}
	if old == nil && n >= maxRecvsPerPeer {
		m.recvMu.Unlock()
		refuse(errors.New("too many transfers at once"))
		return
	}
	delete(m.recvs, key)
	m.recvMu.Unlock()
	if old != nil {
		old.stop() // an older connection's attempt; this one takes over
	}

	rf, err := m.openPart(key, msg)
	if err != nil {
		refuse(err)
		return
	}
	rf.owner = p
	m.recvMu.Lock()
	old = m.recvs[key]
	m.recvs[key] = rf
	m.recvMu.Unlock()
	if old != nil {
		old.stop()
	}
	m.emit(map[string]any{"type": "file-begin", "peer": p.id, "id": msg.ID, "ts": msg.TS, "name": rf.name, "size": rf.size, "kind": rf.kind, "have": rf.got})
	if err := p.writeMsg(&wireMsg{T: "file-resume", Ref: msg.ID, Have: rf.got}); err != nil {
		p.conn.Close()
	}
}

// openPart opens the kept .part for key, or a fresh one.
func (m *Manager) openPart(key string, msg *wireMsg) (*recvFile, error) {
	part := m.partPath(key)
	if err := os.MkdirAll(filepath.Dir(part), 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(part, os.O_RDWR|os.O_CREATE, 0600)
	if err != nil {
		return nil, err
	}
	w, have, err := m.cfg.Vault.ResumePart(f)
	if err == nil && have > msg.Size {
		// Not this file after all; start over.
		if err = f.Truncate(0); err == nil {
			if _, err = f.Seek(0, io.SeekStart); err == nil {
				w, have, err = m.cfg.Vault.ResumePart(f)
			}
		}
	}
	if err == nil {
		if free, ok := freeSpace(m.cfg.DownloadDir); ok && free < uint64(msg.Size-have)+freeMargin {
			err = fmt.Errorf("not enough free space for %d bytes", msg.Size-have)
		}
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	name := capName(sanitizeName(msg.File))
	return &recvFile{f: f, w: w, part: part, name: name, kind: MediaKind(name), size: msg.Size, got: have}, nil
}

// takeRecv unlinks p's transfer id, if it is p's.
func (m *Manager) takeRecv(p *peer, id string) *recvFile {
	key := recvKey(p, id)
	m.recvMu.Lock()
	defer m.recvMu.Unlock()
	rf := m.recvs[key]
	if rf == nil || rf.owner != p {
		return nil
	}
	delete(m.recvs, key)
	return rf
}

func (m *Manager) handleChunk(p *peer, id string, chunk []byte) {
	m.recvMu.Lock()
	rf := m.recvs[recvKey(p, id)]
	m.recvMu.Unlock()
	if rf == nil || rf.owner != p {
		return // unknown transfer; drop
	}
	rf.mu.Lock()
	if rf.dead {
		rf.mu.Unlock()
		return
	}
	var err error
	if rf.got+int64(len(chunk)) > rf.size {
		err = errors.New("peer sent more than it offered")
	} else if _, err = rf.w.Write(chunk); err == nil {
		rf.got += int64(len(chunk))
	}
	due := err == nil && rf.prog.due(rf.got, rf.size)
	got := rf.got
	rf.mu.Unlock()
	if err != nil {
		m.logf("tincan: receiving %q: %v", id, err)
		if m.takeRecv(p, id) == rf {
			rf.stop()
			os.Remove(rf.part)
			m.emit(map[string]any{"type": "recv-error", "peer": p.id, "id": id, "error": err.Error()})
		}
		return
	}
	if due {
		m.emit(map[string]any{"type": "file-progress", "peer": p.id, "id": id, "done": got, "size": rf.size})
	}
}

// finishRecv moves a complete file into place and acks it; anything
// short or long of the offer is dropped.
func (m *Manager) finishRecv(p *peer, id string) {
	rf := m.takeRecv(p, id)
	if rf == nil {
		return
	}
	rf.mu.Lock()
	rf.dead = true
	err := error(nil)
	if rf.got != rf.size {
		err = fmt.Errorf("got %d of %d bytes", rf.got, rf.size)
	} else {
		err = rf.w.Close()
	}
	if cerr := rf.f.Close(); err == nil {
		err = cerr
	}
	rf.mu.Unlock()
	var final string
	if err == nil {
		final, err = placePart(rf.part, m.cfg.DownloadDir, rf.name)
	}
	if err != nil {
		m.logf("tincan: finishing %q: %v", rf.name, err)
		os.Remove(rf.part)
		m.emit(map[string]any{"type": "recv-error", "peer": p.id, "id": id, "error": err.Error()})
		return
	}
	m.emit(map[string]any{"type": "file-done", "peer": p.id, "id": id, "path": final, "name": filepath.Base(final), "size": rf.got})
	p.writeMsg(&wireMsg{T: "ack", Ref: id})
}

// placePart renames part to a free variant of dir/name.
func placePart(part, dir, name string) (string, error) {
	for {
		final := uniquePath(dir, name)
		f, err := os.OpenFile(final, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0600)
		if errors.Is(err, os.ErrExist) {
			continue
		}
		if err != nil {
			return "", err
		}
		f.Close()
		if err := os.Rename(part, final); err != nil {
			os.Remove(final)
			return "", err
		}
		return final, nil
	}
}

// abortRecvs stops the transfers a closed connection left unfinished,
// keeping what arrived for a resume.
func (m *Manager) abortRecvs(p *peer) {
	m.recvMu.Lock()
	var ids []string
	var rfs []*recvFile
	for key, rf := range m.recvs {
		if rf.owner == p {
			delete(m.recvs, key)
			ids = append(ids, strings.TrimPrefix(key, p.id+"\x00"))
			rfs = append(rfs, rf)
		}
	}
	m.recvMu.Unlock()
	for i, rf := range rfs {
		rf.stop()
		m.emit(map[string]any{"type": "recv-error", "peer": p.id, "id": ids[i]})
	}
}

// sweepStale removes leftovers of transfers and atomic writes that
// nothing resumed in a week.
func sweepStale(dirs ...string) {
	cutoff := time.Now().Add(-staleAfter)
	for _, dir := range dirs {
		filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			name := d.Name()
			if !strings.HasSuffix(name, ".part") && !(strings.HasPrefix(name, ".") && strings.Contains(name, ".tmp")) {
				return nil
			}
			if fi, err := d.Info(); err == nil && fi.ModTime().Before(cutoff) {
				os.Remove(path)
			}
			return nil
		})
	}
}

// sanitizeName reduces a peer-supplied filename to a safe base name.
func sanitizeName(name string) string {
	name = cleanText(name)
	name = filepath.Base(strings.ReplaceAll(name, "\\", "/"))
	name = strings.TrimLeft(name, ".")
	if name == "" || strings.Contains(name, "/") {
		name = "file"
	}
	return name
}

// cleanText drops what can hide or reorder text on screen: control
// characters (NUL included), bidi overrides and invalid UTF-8.
func cleanText(s string) string {
	return strings.Map(func(r rune) rune {
		if r == utf8.RuneError || unicode.IsControl(r) || isBidiControl(r) {
			return -1
		}
		return r
	}, s)
}

func isBidiControl(r rune) bool {
	return r == 0x061C || r == 0x200E || r == 0x200F ||
		r >= 0x202A && r <= 0x202E || r >= 0x2066 && r <= 0x2069
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
