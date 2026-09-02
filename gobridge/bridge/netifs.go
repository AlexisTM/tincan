package bridge

import (
	"encoding/json"
	"net"
	"sync"

	"tailscale.com/net/netmon"
)

// Android denies netlink interface enumeration to apps, so the host
// feeds the list in from Java and netmon reads that instead of
// net.Interfaces.

// NetInterface is one interface as reported by the host.
type NetInterface struct {
	Name         string   `json:"name"`
	Index        int      `json:"index"`
	MTU          int      `json:"mtu"`
	Up           bool     `json:"up"`
	Loopback     bool     `json:"loopback"`
	PointToPoint bool     `json:"pointToPoint"`
	Multicast    bool     `json:"multicast"`
	Addrs        []string `json:"addrs"` // CIDR
}

var (
	netifMu   sync.Mutex
	netifList []netmon.Interface
)

// SetNetInterfacesJSON installs the host's interface list. Call before
// Manager.Start and on every connectivity change. An empty list is
// ignored: a stale view beats none.
func SetNetInterfacesJSON(j string) error {
	var list []NetInterface
	if err := json.Unmarshal([]byte(j), &list); err != nil {
		return err
	}
	conv := make([]netmon.Interface, 0, len(list))
	for _, e := range list {
		var flags net.Flags
		if e.Up {
			flags |= net.FlagUp | net.FlagRunning
		}
		if e.Loopback {
			flags |= net.FlagLoopback
		}
		if e.PointToPoint {
			flags |= net.FlagPointToPoint
		}
		if e.Multicast {
			flags |= net.FlagMulticast
		}
		var addrs []net.Addr
		for _, c := range e.Addrs {
			ip, ipnet, err := net.ParseCIDR(c)
			if err != nil {
				continue
			}
			addrs = append(addrs, &net.IPNet{IP: ip, Mask: ipnet.Mask})
		}
		mtu := e.MTU
		if mtu <= 0 {
			mtu = 1500
		}
		conv = append(conv, netmon.Interface{
			Interface: &net.Interface{Index: e.Index, MTU: mtu, Name: e.Name, Flags: flags},
			AltAddrs:  addrs,
		})
	}
	if len(conv) == 0 {
		return nil
	}
	netifMu.Lock()
	first := netifList == nil
	netifList = conv
	netifMu.Unlock()
	if first {
		netmon.RegisterInterfaceGetter(func() ([]netmon.Interface, error) {
			netifMu.Lock()
			defer netifMu.Unlock()
			return netifList, nil
		})
	}
	return nil
}
