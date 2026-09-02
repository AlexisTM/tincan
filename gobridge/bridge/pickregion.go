package bridge

import (
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"runtime"
	"sync"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/logger"
)

// pickNearestRegion finds the closest DERP region for a first run.
// tailcat's own picker needs interface enumeration, which Android
// denies apps and where it nil-panics, so mobile always probes over
// HTTPS and the rest fall back to it.
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

// probeRegionsHTTP races one /derp/probe round-trip per region.
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
		if len(reg.Nodes) == 0 || reg.Avoid {
			continue
		}
		probes++
		wg.Add(1)
		go func(reg *tailcfg.DERPRegion) {
			defer wg.Done()
			node := reg.Nodes[0]
			port := node.DERPPort
			if port == 0 {
				port = 443
			}
			client := &http.Client{
				Transport: &http.Transport{
					TLSClientConfig: &tls.Config{InsecureSkipVerify: node.InsecureForTests},
				},
			}
			defer client.CloseIdleConnections()
			url := fmt.Sprintf("https://%s:%d/derp/probe", node.HostName, port)
			req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
			if err != nil {
				return
			}
			t0 := time.Now()
			resp, err := client.Do(req)
			if err != nil {
				return
			}
			resp.Body.Close()
			select {
			case results <- answer{reg, time.Since(t0)}:
			case <-ctx.Done():
			}
		}(reg)
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
