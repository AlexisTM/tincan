package bridge

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"runtime"
	"strconv"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/logger"
)

// pickNearestRegion finds the closest DERP region; mobile skips netcheck for HTTPS probes.
func pickNearestRegion(ctx context.Context, mapURL string, logf logger.Logf) (*tailcfg.DERPRegion, error) {
	dm, err := tailcat.FetchDERPMap(ctx, derpOpts(mapURL)...)
	if err != nil {
		return nil, fmt.Errorf("fetching DERP map: %w", err)
	}
	if runtime.GOOS != "android" && runtime.GOOS != "ios" {
		reg, err := pickViaNetcheck(ctx, dm)
		if err == nil {
			return reg, nil
		}
		logf("tincan: netcheck region pick failed (%v); probing over HTTPS", err)
	}
	return probeRegionsHTTP(ctx, dm)
}

// derpOpts omits the URL when empty; tailcat reads an empty one as the
// literal URL to fetch, not as "use the default".
func derpOpts(mapURL string) []any {
	opts := []any{tailcat.ExpandForServer}
	if mapURL != "" {
		opts = append(opts, tailcat.DERPMapURL(mapURL))
	}
	return opts
}

// pickViaNetcheck measures over STUN. It fails rather than guess when
// nothing answers: a guessed region would be pinned for good.
func pickViaNetcheck(ctx context.Context, dm *tailcfg.DERPMap) (reg *tailcfg.DERPRegion, err error) {
	// Only catches panics on this goroutine, not in netcheck's own.
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("netcheck panicked: %v", r)
		}
	}()
	id, err := tailcat.PickBestRegion(ctx, dm)
	if err != nil {
		return nil, err
	}
	if reg = dm.Regions[id]; reg == nil {
		return nil, fmt.Errorf("no region answered netcheck")
	}
	return reg, nil
}

const probeGrace = 150 * time.Millisecond

// probeRegionsHTTP races a /derp/probe round-trip to every DERP node.
func probeRegionsHTTP(ctx context.Context, dm *tailcfg.DERPMap) (*tailcfg.DERPRegion, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	type answer struct {
		reg *tailcfg.DERPRegion
		rtt time.Duration
	}
	results := make(chan answer)
	var wg sync.WaitGroup
	probes := 0
	for _, reg := range dm.Regions {
		if reg.Avoid || reg.NoMeasureNoHome {
			continue
		}
		for _, node := range reg.Nodes {
			if node.STUNOnly {
				continue
			}
			probes++
			wg.Add(1)
			go func() {
				defer wg.Done()
				if rtt, ok := probeNode(ctx, node); ok {
					select {
					case results <- answer{reg, rtt}:
					case <-ctx.Done():
					}
				}
			}()
		}
	}
	if probes == 0 {
		return nil, fmt.Errorf("DERP map has no usable regions")
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	// The first answer is nearly always the nearest; a short grace lets
	// a close runner-up still win without waiting on the stragglers.
	var best *answer
	var grace <-chan time.Time
collect:
	for {
		select {
		case a, ok := <-results:
			if !ok {
				break collect
			}
			if best == nil || a.rtt < best.rtt {
				best = &a
			}
			if grace == nil {
				grace = time.After(probeGrace)
			}
		case <-grace:
			break collect
		}
	}
	cancel()
	if best == nil {
		return nil, fmt.Errorf("no DERP region answered an HTTPS probe")
	}
	return best.reg, nil
}

func probeNode(ctx context.Context, node *tailcfg.DERPNode) (time.Duration, bool) {
	port := node.DERPPort
	if port == 0 {
		port = 443
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.TLSClientConfig = &tls.Config{InsecureSkipVerify: node.InsecureForTests}
	client := &http.Client{Transport: tr}
	defer client.CloseIdleConnections()
	url := "https://" + net.JoinHostPort(node.HostName, strconv.Itoa(port)) + "/derp/probe"
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return 0, false
	}
	t0 := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return 0, false
	}
	resp.Body.Close()
	return time.Since(t0), resp.StatusCode >= 200 && resp.StatusCode < 300
}
