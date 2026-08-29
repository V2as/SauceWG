// awg-bypass reopens destinations whose IPv4 a censor filters but whose packets
// still reach the entry node's own uplink.
//
// It is the entry node's answer to a censor that blocks a service at the point
// where a TCP connection is established rather than by route: the SYN to the
// service's IPv4 is dropped, so nothing ever connects, while ICMP to the same
// address and every already-established flow pass untouched. Nothing about the
// tunnel can help there — the block is on the far side of it — and the cascade
// solves it only by leaving the country. This carries the same flow out of the
// same entry node by a path the filter is not watching.
//
// Client traffic for a listed prefix is REDIRECTed here by the node container.
// The original destination survives the redirect in the socket, so this reads it
// back and opens the outbound half itself, one of two ways:
//
//	v6     the destination's IPv6 counterpart, from the mapping table. Filters
//	       are routinely built for a service's IPv4 prefixes alone, and the same
//	       server answers on IPv6 in a single attempt.
//	retry  the destination's own IPv4, dialled repeatedly and several at a time. A
//	       filter that drops a percentage of handshakes rather than all of them is
//	       beaten by trying until one lands; the connection that results is a
//	       normal one, at full speed, because only establishment was ever being
//	       dropped. Handshakes go out in a burst rather than one after another
//	       because the client is waiting: against an address losing nine SYNs in
//	       ten, a burst lands in well under a second where a single file of
//	       attempts takes ten.
//
// The two are tried in that order and the second is what makes the first safe to
// ship a table for: a destination the table does not know, or whose IPv6 has been
// filtered too, is still dialled the ordinary way, so the worst case is the
// behaviour of not having run this at all. The second is also the only path that
// exists for a service with no IPv6 at all — Telegram's media CDN publishes none
// — so it carries photographs and video, not just the fallback.
//
// A destination that cannot be reached either way is remembered for a few
// seconds, and during those seconds it costs one handshake instead of a burst.
// Clients retry a failing address in tight loops, and without that the cheapest
// path through this code would be the one taken tens of thousands of times a
// minute.
//
// The bytes are spliced verbatim. Nothing here terminates TLS, parses MTProto or
// needs to: to both ends this is the transport, and the connection is
// indistinguishable from one the client opened itself.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Linux's SO_ORIGINAL_DST. Absent from the syscall package, and its value is
// stable ABI.
const soOriginalDst = 80

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

type mapping struct {
	Prefix string `json:"prefix"`
	V6     string `json:"v6"`
	Note   string `json:"note,omitempty"`
}

type config struct {
	Listen string    `json:"listen"`
	Map    []mapping `json:"map"`

	// How hard to try the destination's own IPv4 once IPv6 is unavailable or has
	// failed. A filter dropping 19 handshakes in 20 needs tens of attempts, and
	// each one costs nothing but a SYN — but the client is waiting, so the budget
	// is bounded in time as well as in attempts.
	Attempts       int `json:"attempts"`
	AttemptTimeout int `json:"attempt_timeout_ms"`
	RetryBudget    int `json:"retry_budget_ms"`
	// How many of those attempts may be outstanding at once. This is what turns
	// the budget from a ten-second wait into a sub-second one; it is bounded
	// because every outstanding attempt holds an ephemeral port and a conntrack
	// entry on the entry node.
	Parallel int `json:"parallel"`
	// One IPv6 attempt, kept short: the point of the IPv6 path is that it answers
	// immediately, and a long wait here would delay the retry path behind it.
	V6Timeout int `json:"v6_timeout_ms"`
	// How long a destination that spent a whole budget without connecting is
	// treated as hopeless, and how many such rounds it takes to get there.
	Cooldown  int `json:"cooldown_ms"`
	CoolAfter int `json:"cool_after"`
}

// A prefix and the address to reach the same server at over IPv6.
type route struct {
	prefix netip.Prefix
	v6     netip.Addr
	note   string
}

// The parsed form of a config, swapped in whole so a reload never leaves a
// half-applied table behind.
type table struct {
	listen  string
	routes  []route // longest prefix first
	attempt time.Duration
	budget  time.Duration
	tries   int
	width   int
	v6wait  time.Duration
	// What a destination that keeps spending whole budgets gets instead. Derived
	// rather than configured: there is one decision here — how hard to try — and
	// it should not have to be made twice.
	coolTries  int
	coolWidth  int
	coolBudget time.Duration
	cooldown   time.Duration
	coolAfter  int
}

func defaults() config {
	return config{
		Attempts:       96,
		AttemptTimeout: 400,
		RetryBudget:    20000,
		Parallel:       6,
		V6Timeout:      4000,
		Cooldown:       10000,
		CoolAfter:      3,
	}
}

func parse(raw []byte) (*table, error) {
	cfg := defaults()
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, err
	}
	if cfg.Listen == "" {
		return nil, errors.New("no listen address")
	}

	t := &table{
		listen:    cfg.Listen,
		tries:     cfg.Attempts,
		width:     cfg.Parallel,
		attempt:   time.Duration(cfg.AttemptTimeout) * time.Millisecond,
		budget:    time.Duration(cfg.RetryBudget) * time.Millisecond,
		v6wait:    time.Duration(cfg.V6Timeout) * time.Millisecond,
		cooldown:  time.Duration(cfg.Cooldown) * time.Millisecond,
		coolAfter: cfg.CoolAfter,
	}
	// A config that switches the burst off must still dial once, or a listed
	// destination would be reachable by no path at all.
	if t.width < 1 {
		t.width = 1
	}
	if t.tries < 1 {
		t.tries = 1
	}
	t.coolTries = max(t.tries/12, 1)
	t.coolWidth = max(t.width/2, 1)
	// Bounded in time as well, because this is the path a client waits on for a
	// destination that is not going to answer: a second is long enough to catch
	// one that has started answering and short enough to send the client on to
	// the next address in its own list.
	t.coolBudget = min(t.budget, 1500*time.Millisecond)
	for _, m := range cfg.Map {
		prefix, err := netip.ParsePrefix(m.Prefix)
		if err != nil {
			// One unusable line must not cost the table every other prefix.
			log.Printf("skipping mapping %q: %v", m.Prefix, err)
			continue
		}
		if !prefix.Addr().Is4() {
			log.Printf("skipping mapping %q: not an IPv4 prefix", m.Prefix)
			continue
		}
		var v6 netip.Addr
		if m.V6 != "" {
			v6, err = netip.ParseAddr(m.V6)
			if err != nil || !v6.Is6() || v6.Is4In6() {
				log.Printf("skipping mapping %q: %q is not an IPv6 address", m.Prefix, m.V6)
				v6 = netip.Addr{}
			}
		}
		t.routes = append(t.routes, route{prefix: prefix.Masked(), v6: v6, note: m.Note})
	}
	// Longest prefix first, so a per-address entry wins over the range it sits in
	// and a first match is the most specific one.
	sort.SliceStable(t.routes, func(i, j int) bool {
		return t.routes[i].prefix.Bits() > t.routes[j].prefix.Bits()
	})
	return t, nil
}

func (t *table) lookup(addr netip.Addr) (netip.Addr, bool) {
	for _, r := range t.routes {
		if r.prefix.Contains(addr) {
			return r.v6, r.v6.IsValid()
		}
	}
	return netip.Addr{}, false
}

// ---------------------------------------------------------------------------
// Destinations that are not answering
// ---------------------------------------------------------------------------

// Remembers destinations that spent a whole budget without connecting.
//
// Not a health check and not a decision to give up: a cooled destination is
// still dialled on every flow that asks for it, with a short burst instead of a
// long one. What it stops is the waste, and the waste is enormous — two kinds of
// destination arrive here and they need opposite treatment:
//
//	sampled   the filter drops most handshakes and answers some. Persistence is
//	          exactly right: measured against a live entry node, two thirds of
//	          these open within six handshakes and the rest trail out to sixty.
//	blocked   the filter answers none of them, ever. Persistence buys nothing,
//	          and because a client that fails retries within the second — several
//	          clients at once, on several ports — one such address accounted for
//	          98% of all failed flows and three hundred thousand handshakes in a
//	          quarter of an hour.
//
// The two are indistinguishable on the first flow and obvious after a few, so
// this is what tells them apart: a destination that spends whole budgets without
// answering gets a shorter burst and a faster failure, and the interval doubles
// each time it goes on failing. A single flow that connects clears the record, so
// a filter that stops dropping is noticed at once rather than waited out.
//
// Failing fast also suits the clients better than persistence does. A Telegram
// client walks a list of datacenter addresses; the sooner one is refused, the
// sooner it tries the next, which may well be one this can open.
type fuses struct {
	mu   sync.Mutex
	seen map[netip.AddrPort]*fuse
}

type fuse struct {
	rounds int       // consecutive budgets spent without connecting
	until  time.Time // while set in the future, only one handshake is spent here
}

// Far above the number of destinations that can plausibly be failing at once, and
// small enough to be irrelevant next to the connections themselves.
const maxFuses = 4096

// Where the doubling stops. Long enough that an address which is simply blocked
// stops costing full bursts, short enough that a censor lifting a block is
// noticed the same afternoon — and it is noticed sooner than this anyway, because
// a cooled destination is still being dialled on every flow.
const maxCooldown = 5 * time.Minute

func newFuses() *fuses { return &fuses{seen: make(map[netip.AddrPort]*fuse)} }

// Whether this destination is currently on the short burst.
func (f *fuses) cool(dst netip.AddrPort, now time.Time) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	entry, ok := f.seen[dst]
	return ok && now.Before(entry.until)
}

func (f *fuses) failed(dst netip.AddrPort, now time.Time, after int, cooldown time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	entry, ok := f.seen[dst]
	if !ok {
		// Bounded, and tidied only when it grows: the working set is the number of
		// destinations failing at once, which is small, but a censor changing its
		// mind about a whole range must not be able to grow this without limit.
		if len(f.seen) >= maxFuses {
			f.prune(now)
			// Still full, so every entry is live: something is being dropped across
			// a whole range at once. Which of them is forgotten does not matter —
			// a forgotten destination costs one burst the next time a client asks
			// for it, not a wrong answer — but the map has to stop growing.
			for old := range f.seen {
				if len(f.seen) < maxFuses {
					break
				}
				delete(f.seen, old)
			}
		}
		entry = &fuse{}
		f.seen[dst] = entry
	}
	entry.rounds++
	if entry.rounds < after {
		return
	}
	// Doubling, because the two populations separate over time and nothing else
	// here distinguishes them: a destination whose handshakes are merely being
	// sampled connects sooner or later and clears its record, while one that is
	// blocked outright keeps failing and settles at the ceiling, where it costs
	// almost nothing to keep an eye on.
	wait := cooldown << min(entry.rounds-after, 16)
	if wait > maxCooldown || wait <= 0 {
		wait = maxCooldown
	}
	entry.until = now.Add(wait)
}

// A destination that answers is forgotten: the next failure starts over, so a
// filter that stops dropping is noticed on the first flow rather than waited out.
func (f *fuses) answered(dst netip.AddrPort) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.seen, dst)
}

func (f *fuses) prune(now time.Time) {
	for dst, entry := range f.seen {
		if now.After(entry.until) {
			delete(f.seen, dst)
		}
	}
}

// ---------------------------------------------------------------------------
// Counters
// ---------------------------------------------------------------------------

// What the node container republishes into uplinks.json, so `saucewg bypass`,
// the API and the panel can all say whether this is doing anything.
type counters struct {
	open     atomic.Int64
	accepted atomic.Int64
	viaV6    atomic.Int64
	viaRetry atomic.Int64
	failed   atomic.Int64
	rx       atomic.Int64
	tx       atomic.Int64
	// Attempts spent on the retry path, which is the honest measure of how hard
	// the filter is dropping handshakes.
	syns atomic.Int64
	// Flows that arrived for a destination already known not to be answering, and
	// so were given one handshake rather than a burst. High and rising means
	// clients are hammering something that is blocked by address rather than
	// having its handshakes sampled.
	cooled atomic.Int64

	mu       sync.Mutex
	lastErr  string
	lastAt   time.Time
	routes   int
	listenOn string
}

func (c *counters) fail(err error) {
	c.failed.Add(1)
	c.mu.Lock()
	c.lastErr = err.Error()
	c.lastAt = time.Now()
	c.mu.Unlock()
}

func (c *counters) snapshot() []byte {
	c.mu.Lock()
	lastErr, lastAt, routes, listen := c.lastErr, c.lastAt, c.routes, c.listenOn
	c.mu.Unlock()

	payload := map[string]any{
		"pid":       os.Getpid(),
		"listen":    listen,
		"prefixes":  routes,
		"open":      c.open.Load(),
		"accepted":  c.accepted.Load(),
		"via_v6":    c.viaV6.Load(),
		"via_retry": c.viaRetry.Load(),
		"failed":    c.failed.Load(),
		"attempts":  c.syns.Load(),
		"cooled":    c.cooled.Load(),
		"rx_bytes":  c.rx.Load(),
		"tx_bytes":  c.tx.Load(),
	}
	if lastErr != "" {
		payload["last_error"] = lastErr
		payload["last_error_at"] = lastAt.Unix()
	}
	out, err := json.Marshal(payload)
	if err != nil {
		return []byte("{}")
	}
	return out
}

// ---------------------------------------------------------------------------
// The original destination
// ---------------------------------------------------------------------------

// Where the client was actually going, before the redirect rewrote it. The
// kernel keeps it on the socket; without it every redirected flow would look
// like it was addressed to this listener.
func originalDst(conn *net.TCPConn) (netip.AddrPort, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return netip.AddrPort{}, err
	}
	// A sockaddr_in is the same sixteen bytes as an ipv6_mreq, which is the only
	// shape the syscall package will hand back for an opaque option.
	var sa *syscall.IPv6Mreq
	var inner error
	if err := raw.Control(func(fd uintptr) {
		sa, inner = syscall.GetsockoptIPv6Mreq(int(fd), syscall.IPPROTO_IP, soOriginalDst)
	}); err != nil {
		return netip.AddrPort{}, err
	}
	if inner != nil {
		return netip.AddrPort{}, inner
	}
	// struct sockaddr_in: family (2) port (2, network order) address (4).
	port := uint16(sa.Multiaddr[2])<<8 | uint16(sa.Multiaddr[3])
	addr := netip.AddrFrom4([4]byte{sa.Multiaddr[4], sa.Multiaddr[5], sa.Multiaddr[6], sa.Multiaddr[7]})
	return netip.AddrPortFrom(addr, port), nil
}

// ---------------------------------------------------------------------------
// Dialling
// ---------------------------------------------------------------------------

// The outbound half. IPv6 first when the table knows a counterpart, then the
// destination's own IPv4 until a handshake lands or the budget runs out.
func (s *server) dial(dst netip.AddrPort) (net.Conn, string, error) {
	t := s.current()

	if v6, ok := t.lookup(dst.Addr()); ok {
		target := net.JoinHostPort(v6.String(), fmt.Sprint(dst.Port()))
		conn, err := s.dialTCP("tcp6", target, t.v6wait)
		if err == nil {
			s.stats.viaV6.Add(1)
			return conn, "v6", nil
		}
		// Not fatal, and not even unusual: a censor that has learned to filter the
		// IPv6 too lands here, and so does an IPv6 address the table has outlived.
		log.Printf("%s: IPv6 via %s failed (%v); falling back to IPv4", dst, v6, err)
	}

	conn, attempts, err := s.burst(dst, t)
	if err != nil {
		return nil, "", err
	}
	if attempts > 1 {
		log.Printf("%s: IPv4 connected after %d handshake(s)", dst, attempts)
	}
	s.stats.viaRetry.Add(1)
	return conn, "retry", nil
}

// The retry path: handshakes to the destination's own IPv4 until one is answered.
//
// Several are outstanding at once, and the first answer wins. Each attempt is an
// independent sample of a filter that drops most but not all handshakes, so the
// burst is what makes the difference between a connection in half a second and
// one in ten — and the client is waiting through every one of them.
//
// Returns how many handshakes it took, for the log.
func (s *server) burst(dst netip.AddrPort, t *table) (net.Conn, int, error) {
	target := dst.String()
	now := time.Now()

	// Already known not to be answering: a short burst rather than a long one.
	// Short enough that a hopeless address costs a twelfth of what it did, wide
	// enough to still catch the two thirds of reachable destinations that open
	// within the first few handshakes.
	tries, width, budget := t.tries, t.width, t.budget
	if s.fuses.cool(dst, now) {
		s.stats.cooled.Add(1)
		tries, width, budget = t.coolTries, t.coolWidth, t.coolBudget
	}

	deadline := now.Add(budget)
	type outcome struct {
		conn net.Conn
		err  error
	}
	// One slot per attempt that can be outstanding, so reporting never blocks: an
	// attempt that blocked on a send would hold its socket open for as long as
	// nobody was reading, which is exactly the case this has to survive.
	answers := make(chan outcome, width)

	dial := func() {
		conn, err := s.dialTCP("tcp4", target, t.attempt)
		answers <- outcome{conn, err}
	}

	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()

	var last error
	spent, inFlight := 0, 0

	// The attempts still outstanding when this returns will report in their own
	// time, and some of them will have connected — a burst of six against a filter
	// that drops five is one connection wanted and several more arriving late. A
	// connection nobody is going to read has to be closed rather than dropped on
	// the floor: the garbage collector does not close sockets.
	defer func() {
		if inFlight == 0 {
			return
		}
		go func(pending int) {
			for i := 0; i < pending; i++ {
				if answer := <-answers; answer.conn != nil {
					answer.conn.Close()
				}
			}
		}(inFlight)
	}()
	for {
		for inFlight < width && spent < tries && time.Now().Before(deadline) {
			s.stats.syns.Add(1)
			spent++
			inFlight++
			go dial()
		}
		if inFlight == 0 {
			break
		}
		select {
		case answer := <-answers:
			inFlight--
			if answer.err == nil {
				s.fuses.answered(dst)
				return answer.conn, spent, nil
			}
			last = answer.err
			// A refusal is an answer: the far end is reachable and said no, so
			// trying again would only be slower about reporting it. Only a silent
			// drop — which is what the filter does — is worth another handshake.
			if !isTimeout(answer.err) {
				s.fuses.answered(dst)
				return nil, spent, answer.err
			}
		case <-timer.C:
			last = fmt.Errorf("no handshake was answered in %s (%d sent)", budget, spent)
			s.fuses.failed(dst, time.Now(), t.coolAfter, t.cooldown)
			return nil, spent, last
		}
	}
	if last == nil {
		last = errors.New("no connection attempt was made")
	}
	s.fuses.failed(dst, time.Now(), t.coolAfter, t.cooldown)
	return nil, spent, last
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

// How a handshake is made. Only the tests replace it: what the burst does under a
// filter that answers one handshake in twenty cannot be reproduced with a real
// socket, and it is the part of this program most worth being sure about.
type dialFunc func(network, address string, timeout time.Duration) (net.Conn, error)

type server struct {
	stats   counters
	tbl     atomic.Pointer[table]
	fuses   *fuses
	dialTCP dialFunc
}

func (s *server) current() *table { return s.tbl.Load() }

func (s *server) handle(client *net.TCPConn) {
	defer client.Close()
	s.stats.accepted.Add(1)
	s.stats.open.Add(1)
	defer s.stats.open.Add(-1)

	dst, err := originalDst(client)
	if err != nil {
		s.stats.fail(fmt.Errorf("could not read the original destination: %w", err))
		return
	}

	upstream, how, err := s.dial(dst)
	if err != nil {
		s.stats.fail(fmt.Errorf("%s: %w", dst, err))
		log.Printf("%s: could not be reached: %v", dst, err)
		return
	}
	defer upstream.Close()

	if tcp, ok := upstream.(*net.TCPConn); ok {
		tcp.SetNoDelay(true)
	}
	client.SetNoDelay(true)
	log.Printf("%s: open via %s", dst, how)

	// Each direction closes its own write side on EOF so a half-closed flow — an
	// HTTP request that is finished sending but still reading — is not torn down
	// under a client that is waiting for the rest of the answer.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		n, _ := io.Copy(upstream, client)
		s.stats.tx.Add(n)
		if tcp, ok := upstream.(*net.TCPConn); ok {
			tcp.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		n, _ := io.Copy(client, upstream)
		s.stats.rx.Add(n)
		client.CloseWrite()
	}()
	wg.Wait()
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

func (s *server) load(path string) (*table, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	t, err := parse(raw)
	if err != nil {
		return nil, err
	}
	previous := s.current()
	if previous != nil && previous.listen != t.listen {
		// The listener is bound for the life of the process; the node container
		// restarts it when the address changes, so refusing here is honest rather
		// than pretending to have moved.
		return nil, fmt.Errorf("the listen address changed from %s to %s", previous.listen, t.listen)
	}
	s.tbl.Store(t)
	s.stats.mu.Lock()
	s.stats.routes = len(t.routes)
	s.stats.listenOn = t.listen
	s.stats.mu.Unlock()
	return t, nil
}

// Republished on a timer rather than on change: the node container reads it on
// its own health tick and a fixed cadence is what makes a stale file mean the
// process died.
func (s *server) publish(path string) {
	if path == "" {
		return
	}
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	if err := os.WriteFile(tmp, s.stats.snapshot(), 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
	}
}

func main() {
	configPath := flag.String("config", "/var/run/amneziawg/bypass.json", "mapping table")
	statePath := flag.String("state", "/var/run/amneziawg/bypass-state.json", "where to publish counters")
	flag.Parse()

	log.SetFlags(log.Ldate | log.Ltime)
	log.SetPrefix("bypass: ")

	s := &server{fuses: newFuses(), dialTCP: net.DialTimeout}
	t, err := s.load(*configPath)
	if err != nil {
		log.Fatalf("cannot start: %v", err)
	}

	listener, err := net.Listen("tcp4", t.listen)
	if err != nil {
		log.Fatalf("cannot listen on %s: %v", t.listen, err)
	}
	log.Printf("listening on %s for %d prefix(es)", t.listen, len(t.routes))

	// SIGHUP is how the node container hands over a new table; the mtime poll is
	// what makes an edit by hand work too.
	reload := make(chan os.Signal, 1)
	signal.Notify(reload, syscall.SIGHUP)
	go func() {
		var seen time.Time
		if info, err := os.Stat(*configPath); err == nil {
			seen = info.ModTime()
		}
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		publish := time.NewTicker(5 * time.Second)
		defer publish.Stop()
		for {
			select {
			case <-reload:
			case <-publish.C:
				s.publish(*statePath)
				continue
			case <-ticker.C:
				info, err := os.Stat(*configPath)
				if err != nil || !info.ModTime().After(seen) {
					continue
				}
				seen = info.ModTime()
			}
			if updated, err := s.load(*configPath); err != nil {
				log.Printf("keeping the running table: %v", err)
			} else {
				log.Printf("reloaded: %d prefix(es)", len(updated.routes))
			}
		}
	}()
	s.publish(*statePath)

	for {
		conn, err := listener.Accept()
		if err != nil {
			// A closed listener is a shutdown; anything else is transient and
			// abandoning the loop would silently stop carrying traffic.
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Printf("accept failed: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		tcp, ok := conn.(*net.TCPConn)
		if !ok {
			conn.Close()
			continue
		}
		go s.handle(tcp)
	}
}
