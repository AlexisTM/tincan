// Command cshared builds the bridge as a C shared library for Dart FFI.
// Exports take and return UTF-8 JSON; free returned strings with
// TincanFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"sync"
	"time"
	"unsafe"

	"tincan.dev/gobridge/bridge"
)

var (
	mu    sync.Mutex // not reentrant
	mgr   *bridge.Manager
	vault *bridge.Vault
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

func decodeArg[T any](s *C.char) (T, error) {
	var v T
	err := json.Unmarshal([]byte(C.GoString(s)), &v)
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

//export TincanExportAccount
func TincanExportAccount(dst *C.char) *C.char {
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.ExportAccount(C.GoString(dst))
	})
}

//export TincanImportAccount
func TincanImportAccount(src *C.char) *C.char {
	return withVault(func(v *bridge.Vault) (map[string]any, error) {
		return nil, v.ImportAccount(C.GoString(src))
	})
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
		DERPHost    string `json:"derpHost"`
		DERPMapURL  string `json:"derpMapUrl"`
		Verbose     bool   `json:"verbose"`
	}](cfgJSON)
	if err != nil {
		return result(nil, err)
	}
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
	bcfg := bridge.Config{
		Vault:       v,
		StateDir:    cfg.StateDir,
		DownloadDir: cfg.DownloadDir,
		Name:        cfg.Name,
		DERPHost:    cfg.DERPHost,
		DERPMapURL:  cfg.DERPMapURL,
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
	carried []string
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
	if len(carried) > 0 {
		ev := carried[0]
		carried = carried[1:]
		pumpMu.Unlock()
		return ev
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
	ev, ok := m.NextEventTimeout(d, cut)
	if !ok {
		return ""
	}
	pumpMu.Lock()
	defer pumpMu.Unlock()
	if gen != pumpGen {
		// Taken just as a newer pump attached; it gets it next.
		carried = append(carried, ev)
		return staleEvent
	}
	return ev
}

// TincanConnect starts a dial and returns the peer's id at once; the
// outcome arrives as peer-added or connect-error.
//
//export TincanConnect
func TincanConnect(token *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		peer, err := m.Connect(C.GoString(token))
		return map[string]any{"peer": peer}, err
	})
}

//export TincanSendText
func TincanSendText(peer, id, body *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return nil, m.SendText(C.GoString(peer), C.GoString(id), C.GoString(body))
	})
}

//export TincanSendFile
func TincanSendFile(peer, id, path *C.char) *C.char {
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		f, err := m.SendFile(C.GoString(peer), C.GoString(id), C.GoString(path))
		return map[string]any{"name": f.Name, "kind": f.Kind, "size": f.Size, "path": f.Path}, err
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

// TincanSetDERP, TincanRestart and TincanResetIdentity return the new
// server-started event.
//
//export TincanSetDERP
func TincanSetDERP(cfgJSON *C.char) *C.char {
	c, err := decodeArg[struct {
		Host   string `json:"host"`
		MapURL string `json:"mapUrl"`
	}](cfgJSON)
	if err != nil {
		return result(nil, err)
	}
	return withManager(func(m *bridge.Manager) (map[string]any, error) {
		return m.SetDERP(c.Host, c.MapURL)
	})
}

//export TincanRestart
func TincanRestart() *C.char {
	return withManager((*bridge.Manager).Restart)
}

//export TincanResetIdentity
func TincanResetIdentity() *C.char {
	return withManager((*bridge.Manager).ResetIdentity)
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
