package bridge

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"tailscale.com/tailcfg"
)

func TestProbeRegionsHTTP(t *testing.T) {
	probeServer := func(delay time.Duration) *httptest.Server {
		s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/derp/probe" {
				http.NotFound(w, r)
				return
			}
			time.Sleep(delay)
		}))
		t.Cleanup(s.Close)
		return s
	}
	regionFor := func(id int, s *httptest.Server) *tailcfg.DERPRegion {
		host, port, _ := net.SplitHostPort(s.Listener.Addr().String())
		portNum, err := strconv.Atoi(port)
		if err != nil {
			t.Fatal(err)
		}
		return &tailcfg.DERPRegion{
			RegionID: tailcfg.DERPRegionID(id),
			Nodes: []*tailcfg.DERPNode{{
				Name: "n", RegionID: tailcfg.DERPRegionID(id), HostName: host,
				DERPPort: portNum, InsecureForTests: true,
			}},
		}
	}

	slow := probeServer(400 * time.Millisecond)
	fast := probeServer(0)
	dm := &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
		1: regionFor(1, slow),
		2: regionFor(2, fast),
		3: {RegionID: 3, Avoid: true, Nodes: []*tailcfg.DERPNode{{HostName: "unused"}}},
	}}

	reg, err := probeRegionsHTTP(context.Background(), dm)
	if err != nil {
		t.Fatal(err)
	}
	if reg.RegionID != 2 {
		t.Errorf("picked region %d, want the fast one (2)", reg.RegionID)
	}

	if _, err := probeRegionsHTTP(context.Background(), &tailcfg.DERPMap{}); err == nil {
		t.Error("empty map should error")
	}
}

// A netcheck that hears nothing must fail, not hand back a guess that
// would be pinned as the user's region.
func TestNetcheckWithoutAnswersFails(t *testing.T) {
	if testing.Short() {
		t.Skip("real STUN round-trip")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	dm := &tailcfg.DERPMap{Regions: map[tailcfg.DERPRegionID]*tailcfg.DERPRegion{
		7: {RegionID: 7, RegionCode: "x", Nodes: []*tailcfg.DERPNode{{
			Name: "x", RegionID: 7, HostName: "127.0.0.1", IPv4: "127.0.0.1", IPv6: "none", STUNPort: 9,
		}}},
	}}
	if reg, err := pickViaNetcheck(ctx, dm); err == nil {
		t.Fatalf("picked region %v with no STUN answer", reg.RegionID)
	}
}
