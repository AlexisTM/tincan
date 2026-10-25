// Command cshared builds the bridge as a C shared library for Dart FFI.
// Exports take and return UTF-8 JSON; free returned strings with
// TincanFree.
package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"strconv"
	"sync"
	"time"
	"unsafe"

	"tincan.dev/gobridge/bridge"
)

var (
	mu    sync.Mutex // not reentrant
	mgr   *bridge.Manager
	vault *bridge.Vault

	// life keeps Lock from closing a Manager while a call is bringing
	// its server up; taken before mu.
	life sync.Mutex
)

func result(v map[string]any, err error) *C.char {
	if v == nil {
		v = map[string]any{}
	}
	if err != nil {
		v["error"] = err.Error()
	}
	j, err := json.Marshal(v)
	if err != nil {
		j, _ = json.Marshal(map[string]any{"error": err.Error()})
	}
	return C.CString(string(j))
}

// decodeArg parses a JSON arg and wipes its copy; decoded strings linger.
func decodeArg[T any](s *C.char) (T, error) {
	var v T
	b := cBytes(s)
	defer clear(b)
	err := json.Unmarshal(b, &v)
	return v, err
}

func withManager(f func(m *bridge.Manager) (map[string]any, error)) *C.char {
	mu.Lock()
	m := mgr
	mu.Unlock()
	if m == nil {
		return result(nil, errors.New("bridge not started"))
	}
	return result(f(m))
}

// withLive runs a call that replaces the server, so Lock waits for it.
func withLive(f func(m *bridge.Manager) (map[string]any, error)) *C.char {
	life.Lock()
	defer life.Unlock()
	return withManager(f)
}

func withVault(f func(v *bridge.Vault) (map[string]any, error)) *C.char {
	mu.Lock()
	v := vault
	mu.Unlock()
	if v == nil {
		return result(nil, errors.New("locked"))
	}
	return result(f(v))
}

func setVault(v *bridge.Vault, err error) *C.char {
	if err != nil {
		return result(nil, err)
	}
	mu.Lock()
	vault = v
	mu.Unlock()
	return result(nil, nil)
}

//export TincanVaultStatus
func TincanVaultStatus(stateDir *C.char) *C.char {
	exists, mode, err := bridge.VaultExists(C.GoString(stateDir))
	return result(map[string]any{"exists": exists, "mode": mode}, err)
}

type vaultArgs struct {
	StateDir string `json:"stateDir"`
	Secret   string `json:"secret"`
	Mode     string `json:"mode"`
}

// TincanVaultCreate sets up encryption on first run. mode is
// "password", "device" or "none" and only steers the unlock UI.
//
//export TincanVaultCreate
func TincanVaultCreate(cfgJSON *C.char) *C.char {
	c, err := decodeArg[vaultArgs](cfgJSON)
	if err != nil {
		return result(nil, err)
	}
	if err := bridge.CreateVault(c.StateDir, c.Secret, c.Mode); err != nil {
		return result(nil, err)
	}
	return setVault(bridge.OpenVault(c.StateDir, c.Secret))
}

//export TincanUnlock
func TincanUnlock(cfgJSON *C.char) *C.char {
	c, err := decodeArg[vaultArgs](cfgJSON)
	if err != nil {
		return result(nil, err)
	}
	return setVault(bridge.OpenVault(c.StateDir, c.Secret))
}

// TincanChangeSecret rewraps the same data key, so switching between
// a password and biometrics leaves the data in place.
//
//export TincanChangeSecret
func TincanChangeSecret(cfgJSON *C.char) *C.char {
	c, err := decodeArg[vaultArgs](cfgJSON)
	if err != nil {
		return result(nil, err)
	}
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.ChangeSecret(c.Secret, c.Mode)
	})
}

// TincanReadState and TincanWriteState let the host keep its own JSON
// files (chat history, settings) in the same vault. A missing file
// has no "content".
//
//export TincanReadState
func TincanReadState(path *C.char) *C.char {
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		b, err := v.ReadFile(C.GoString(path))
		if errors.Is(err, os.ErrNotExist) || err == nil && len(b) == 0 {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		// Raw spares escaping it into a string; result reports bad JSON.
		return map[string]any{"content": json.RawMessage(b)}, nil
	})
}

//export TincanWriteState
func TincanWriteState(path, content *C.char) *C.char {
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.WriteFile(C.GoString(path), []byte(C.GoString(content)), 0600)
	})
}

// TincanDecryptMedia writes the plaintext of a received file to dst,
// for display or for handing to another app.
//
//export TincanDecryptMedia
func TincanDecryptMedia(src, dst *C.char) *C.char {
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.DecryptFile(C.GoString(src), C.GoString(dst))
	})
}

// cBytes copies a C string into bytes we can zero, unlike a Go string.
func cBytes(s *C.char) []byte {
	if s == nil {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(s), C.int(C.strlen(s)))
}

// TincanExportAccount writes the account to dst, sealed under password
// unless it is empty.
//
//export TincanExportAccount
func TincanExportAccount(dst, password *C.char) *C.char {
	pw := cBytes(password)
	defer clear(pw)
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.ExportAccount(C.GoString(dst), pw)
	})
}

//export TincanImportAccount
func TincanImportAccount(src, password *C.char) *C.char {
	pw := cBytes(password)
	defer clear(pw)
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.ImportAccount(C.GoString(src), pw)
	})
}

// TincanSealFile and TincanOpenFile password-wrap a file such as a
// chat backup. Opening an unsealed file copies it, so an empty password
// works until the error says "password required".
//
//export TincanSealFile
func TincanSealFile(src, dst, password *C.char) *C.char {
	pw := cBytes(password)
	defer clear(pw)
	return result(nil, bridge.SealFile(C.GoString(src), C.GoString(dst), pw))
}

//export TincanOpenFile
func TincanOpenFile(src, dst, password *C.char) *C.char {
	pw := cBytes(password)
	defer clear(pw)
	return result(nil, bridge.OpenFile(C.GoString(src), C.GoString(dst), pw))
}

// TincanImportMedia seals src into dir under a free variant of name.
//
//export TincanImportMedia
func TincanImportMedia(src, dir, name *C.char) *C.char {
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		path, err := v.ImportMedia(C.GoString(src), C.GoString(dir), C.GoString(name))
		return map[string]any{"path": path}, err
	})
}

// TincanStart returns the server-started event. If the transport can't
// come up yet, it errors but keeps trying, reporting by events.
//
//export TincanStart
func TincanStart(cfgJSON *C.char) *C.char {
	cfg, err := decodeArg[struct {
		StateDir    string `json:"stateDir"`
		DownloadDir string `json:"downloadDir"`
		Name        string `json:"name"`
		Relay       string `json:"relay"`
		DirectOnly  bool   `json:"directOnly"`
		Verbose     bool   `json:"verbose"`
	}](cfgJSON)
	if err != nil {
		return result(nil, err)
	}
	life.Lock()
	defer life.Unlock()
	mu.Lock()
	if m := mgr; m != nil {
		// The process outlives its UI: Android recreates the activity
		// and Flutter re-runs main() in a fresh isolate while Go state
		// persists. Hand that isolate the running transport.
		mu.Unlock()
		m.Resync()
		return result(m.Started())
	}
	v := vault
	if v == nil {
		mu.Unlock()
		return result(nil, errors.New("locked: unlock before starting"))
	}
	derpHost, derpMapURL := bridge.ParseRelay(cfg.Relay)
	bcfg := bridge.Config{
		Vault:       v,
		StateDir:    cfg.StateDir,
		DownloadDir: cfg.DownloadDir,
		Name:        cfg.Name,
		DERPHost:    derpHost,
		DERPMapURL:  derpMapURL,
		DirectOnly:  cfg.DirectOnly,
	}
	if cfg.Verbose {
		bcfg.Logf = log.Printf
	}
	m := bridge.New(bcfg)
	if err := m.Open(); err != nil {
		mu.Unlock()
		return result(nil, err)
	}
	mgr = m
	mu.Unlock()
	return result(m.Start())
}

// Android can tear down the Flutter engine and start a new one in the
// same process, while the old engine's pump isolate keeps polling. Each
// pump attaches for a generation; older ones are told to stop, so they
// can't swallow events meant for the live engine.
var (
	pumpMu  sync.Mutex
	pumpGen int
	pumpCut = make(chan struct{})
)

const staleEvent = "stale"

// TincanAttachEvents makes the caller the only event consumer and
// returns the generation to pass to TincanNextEvent.
//
//export TincanAttachEvents
func TincanAttachEvents() C.int { return C.int(attachEvents()) }

// TincanNextEvent waits up to timeoutMs, returning "" on timeout so
// the calling thread keeps returning to the host VM, and "stale" once a
// newer pump has attached. Before the bridge starts it just waits, so
// the host can poll from the outset.
//
//export TincanNextEvent
func TincanNextEvent(gen, timeoutMs C.int) *C.char {
	return C.CString(nextEvent(int(gen), time.Duration(timeoutMs)*time.Millisecond))
}

func attachEvents() int {
	pumpMu.Lock()
	defer pumpMu.Unlock()
	pumpGen++
	close(pumpCut)
	pumpCut = make(chan struct{})
	return pumpGen
}

func nextEvent(gen int, d time.Duration) string {
	pumpMu.Lock()
	if gen != pumpGen {
		pumpMu.Unlock()
		return staleEvent
	}
	cut := pumpCut
	pumpMu.Unlock()

	mu.Lock()
	m := mgr
	mu.Unlock()
	if m == nil {
		select {
		case <-time.After(d):
		case <-cut:
		}
		return ""
	}
	// Checked as the event is taken, so a pump retired meanwhile leaves
	// it for the newer one, in order.
	ev, ok := m.NextEventIf(d, cut, func() bool {
		pumpMu.Lock()
		defer pumpMu.Unlock()
		return gen == pumpGen
	})
	if !ok {
		return ""
	}
	return ev
}

// TincanConnect dials and waits for the outcome, returning the peer's
// id or why it failed.
//
//export TincanConnect
func TincanConnect(token *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		peer, err := m.Connect(C.GoString(token))
		return map[string]any{"peer": peer}, err
	})
}

// TincanSendText sends a text; replyTo is the quoted message's id or "".
//
//export TincanSendText
func TincanSendText(peer, id, body, replyTo *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.SendText(C.GoString(peer), C.GoString(id), C.GoString(body), C.GoString(replyTo))
	})
}

// TincanSendReaction reacts to message ref; an empty emoji removes it.
//
//export TincanSendReaction
func TincanSendReaction(peer, id, ref, emoji *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.SendReaction(C.GoString(peer), C.GoString(id), C.GoString(ref), C.GoString(emoji))
	})
}

// TincanSendTimer sets the disappearing timer, in decimal seconds.
//
//export TincanSendTimer
func TincanSendTimer(peer, id, seconds *C.char) *C.char {
	secs, err := strconv.Atoi(C.GoString(seconds))
	if err != nil {
		return result(nil, err)
	}
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.SendTimer(C.GoString(peer), C.GoString(id), secs)
	})
}

//export TincanSendFile
func TincanSendFile(peer, id, path *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		f, err := m.SendFile(C.GoString(peer), C.GoString(id), C.GoString(path))
		return map[string]any{"name": f.Name, "kind": f.Kind, "size": f.Size, "path": f.Path}, err
	})
}

// TincanCancelTransfer stops a file going either way.
//
//export TincanCancelTransfer
func TincanCancelTransfer(peer, id *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.CancelTransfer(C.GoString(peer), C.GoString(id))
	})
}

// TincanSetDirectOnly takes "true" or "false" and applies at once.
//
//export TincanSetDirectOnly
func TincanSetDirectOnly(on *C.char) *C.char {
	b, err := strconv.ParseBool(C.GoString(on))
	if err != nil {
		return result(nil, err)
	}
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		m.SetDirectOnly(b)
		return nil, nil
	})
}

//export TincanSetProfile
func TincanSetProfile(profileJSON *C.char) *C.char {
	p, err := decodeArg[struct {
		Name          string `json:"name"`
		Description   string `json:"description"`
		Status        string `json:"status"`
		AvatarPath    string `json:"avatarPath"`
		AvatarChanged bool   `json:"avatarChanged"`
	}](profileJSON)
	if err != nil {
		return result(nil, err)
	}
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.SetProfile(p.Name, p.Description, p.Status, p.AvatarPath, p.AvatarChanged)
	})
}

// TincanSetRelay, TincanRestart and TincanResetIdentity return the
// new server-started event. relay is a hostname, or an http(s) URL of a
// relay map.
//
//export TincanSetRelay
func TincanSetRelay(relay *C.char) *C.char {
	host, mapURL := bridge.ParseRelay(C.GoString(relay))
	return withLive(func(m *bridge.Manager) (map[string]any, error) {
		return m.SetRelay(host, mapURL)
	})
}

//export TincanRestart
func TincanRestart() *C.char {
	return withLive((*bridge.Manager).Restart)
}

//export TincanResetIdentity
func TincanResetIdentity() *C.char {
	return withLive((*bridge.Manager).ResetIdentity)
}

//export TincanAccept
func TincanAccept(peer *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.Accept(C.GoString(peer))
	})
}

//export TincanBlock
func TincanBlock(peer *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.Block(C.GoString(peer))
	})
}

//export TincanDisconnect
func TincanDisconnect(peer *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.Disconnect(C.GoString(peer))
	})
}

//export TincanIgnore
func TincanIgnore(peer *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.Ignore(C.GoString(peer))
	})
}

//export TincanSetVerified
func TincanSetVerified(peer, verified *C.char) *C.char {
	b, err := strconv.ParseBool(C.GoString(verified))
	if err != nil {
		return result(nil, err)
	}
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.SetVerified(C.GoString(peer), b)
	})
}

// TincanSetActivePeer marks the chat on screen; "" for none.
//
//export TincanSetActivePeer
func TincanSetActivePeer(peer *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		m.SetActivePeer(C.GoString(peer))
		return nil, nil
	})
}

// TincanLock stops the transport and forgets the data key; unlock and
// start again to come back.
//
//export TincanLock
func TincanLock() *C.char {
	life.Lock()
	defer life.Unlock()
	mu.Lock()
	m, v := mgr, vault
	mgr, vault = nil, nil
	mu.Unlock()
	if m != nil {
		m.Close()
	}
	if v != nil {
		v.Lock()
	}
	return result(nil, nil)
}

//export TincanUnblock
func TincanUnblock(peer *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.Unblock(C.GoString(peer))
	})
}

//export TincanListBlocked
func TincanListBlocked() *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return map[string]any{"blocked": m.ListBlocked()}, nil
	})
}

// TincanSetNetInterfaces feeds in host-enumerated interfaces, which
// Android requires. Call before TincanStart and on network changes.
//
//export TincanSetNetInterfaces
func TincanSetNetInterfaces(j *C.char) *C.char {
	return result(nil, bridge.SetNetInterfacesJSON(C.GoString(j)))
}

//export TincanFree
func TincanFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
