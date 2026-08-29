// What is tested here is the behaviour under a censor, which is the only thing
// this program exists for and the only thing a real socket cannot show: dialling
// 149.154.167.51 from a test would prove nothing except where the test ran.
//
// So the handshake is faked, and faked in the shape the entry node actually
// meets: most attempts silently time out, a few are answered, and the ones the
// burst does not need have to be cleaned up rather than leaked.
package main

import (
	"encoding/json"
	"net"
	"net/netip"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// A censor, in the shape of a dialler
// ---------------------------------------------------------------------------

type fakeConn struct {
	net.Conn
	closed atomic.Bool
}

func (c *fakeConn) Close() error {
	c.closed.Store(true)
	return nil
}

// answers after `dropped` handshakes have been silently timed out, which is what
// a filter sampling handshakes looks like from here.
type censor struct {
	mu      sync.Mutex
	seen    int
	inFlite int
	peak    int

	dropped   int           // how many handshakes to swallow before answering
	delay     time.Duration // how long a swallowed handshake takes to give up
	refuse    bool          // answer with a refusal instead of a silence
	handedOut []*fakeConn
}

func (c *censor) dial(network, address string, timeout time.Duration) (net.Conn, error) {
	c.mu.Lock()
	c.seen++
	attempt := c.seen
	c.inFlite++
	if c.inFlite > c.peak {
		c.peak = c.inFlite
	}
	delay := c.delay
	c.mu.Unlock()

	defer func() {
		c.mu.Lock()
		c.inFlite--
		c.mu.Unlock()
	}()

	if c.refuse {
		return nil, syscall.ECONNREFUSED
	}
	if attempt <= c.dropped {
		if delay > 0 {
			time.Sleep(delay)
		}
		// The error a dropped handshake produces: a deadline, not a refusal.
		return nil, os.ErrDeadlineExceeded
	}
	conn := &fakeConn{}
	c.mu.Lock()
	c.handedOut = append(c.handedOut, conn)
	c.mu.Unlock()
	return conn, nil
}

func (c *censor) handshakes() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.seen
}

func (c *censor) concurrency() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.peak
}

func testServer(d dialFunc) *server {
	return &server{fuses: newFuses(), dialTCP: d}
}

func testTable(t *testing.T, body string) *table {
	t.Helper()
	tbl, err := parse([]byte(body))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return tbl
}

var somewhere = netip.MustParseAddrPort("149.154.167.51:443")

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

func TestParseKeepsTheUsableRowsAndOrdersThem(t *testing.T) {
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "map": [
            {"prefix": "149.154.160.0/20", "v6": ""},
            {"prefix": "149.154.167.51/32", "v6": "2001:67c:4e8:f002::a"},
            {"prefix": "nonsense", "v6": "2001:db8::1"},
            {"prefix": "2001:db8::/32", "v6": ""},
            {"prefix": "203.0.113.0/24", "v6": "not-an-address"},
            {"prefix": "198.51.100.7/32", "v6": "::ffff:1.2.3.4"}
        ]
    }`)

	if len(tbl.routes) != 4 {
		t.Fatalf("kept %d rows, want 4 (an unparseable prefix and an IPv6 prefix must be dropped)", len(tbl.routes))
	}
	// Longest prefix first, so a per-address row wins over the range it sits in.
	if got := tbl.routes[0].prefix.Bits(); got != 32 {
		t.Errorf("first row is a /%d, want the most specific one", got)
	}
	if got := tbl.routes[len(tbl.routes)-1].prefix.Bits(); got != 20 {
		t.Errorf("last row is a /%d, want the least specific one", got)
	}
	// A row whose counterpart is unusable stays, and is dialled over IPv4 only:
	// dropping it would take the destination out of the redirect altogether.
	for _, r := range tbl.routes {
		if r.prefix.String() == "203.0.113.0/24" && r.v6.IsValid() {
			t.Error("an unparseable IPv6 counterpart was kept")
		}
		// A v4-mapped address is not IPv6 connectivity and must not be treated as it.
		if r.prefix.String() == "198.51.100.7/32" && r.v6.IsValid() {
			t.Error("a v4-in-v6 address was accepted as a counterpart")
		}
	}
}

func TestParseNeedsSomewhereToListen(t *testing.T) {
	if _, err := parse([]byte(`{"map": []}`)); err == nil {
		t.Fatal("a config with no listen address was accepted")
	}
}

func TestParseFloorsTheBurst(t *testing.T) {
	// A zero would otherwise mean "never dial", which would make a listed
	// destination unreachable by every path.
	tbl := testTable(t, `{"listen": "10.8.0.1:8646", "parallel": 0, "attempts": 0}`)
	if tbl.width < 1 || tbl.tries < 1 {
		t.Fatalf("width=%d tries=%d, want at least one of each", tbl.width, tbl.tries)
	}
}

func TestLookupPrefersTheMostSpecificRow(t *testing.T) {
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "map": [
            {"prefix": "149.154.160.0/20", "v6": ""},
            {"prefix": "149.154.167.51/32", "v6": "2001:67c:4e8:f002::a"}
        ]
    }`)

	v6, ok := tbl.lookup(somewhere.Addr())
	if !ok || v6.String() != "2001:67c:4e8:f002::a" {
		t.Fatalf("lookup gave %v/%v, want the datacenter's own counterpart", v6, ok)
	}
	// A row without a counterpart is a match for the redirect but not for IPv6.
	if _, ok := tbl.lookup(netip.MustParseAddr("149.154.161.1")); ok {
		t.Error("a row with no counterpart offered one")
	}
	if _, ok := tbl.lookup(netip.MustParseAddr("8.8.8.8")); ok {
		t.Error("an address outside every prefix matched")
	}
}

// ---------------------------------------------------------------------------
// The burst
// ---------------------------------------------------------------------------

func TestBurstBeatsAFilterThatDropsMostHandshakes(t *testing.T) {
	// Thirty dropped handshakes, each taking the full attempt timeout to give up:
	// in a single file that is thirty timeouts of waiting, and the client is
	// sitting through all of it.
	c := &censor{dropped: 30, delay: 60 * time.Millisecond}
	s := testServer(c.dial)
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "attempts": 96, "parallel": 6, "attempt_timeout_ms": 100, "retry_budget_ms": 5000
    }`)

	started := time.Now()
	conn, spent, err := s.burst(somewhere, tbl)
	elapsed := time.Since(started)
	if err != nil {
		t.Fatalf("burst failed against a filter that answers eventually: %v", err)
	}
	conn.Close()

	if spent < 31 {
		t.Errorf("connected after %d handshakes, want more than the 30 that were dropped", spent)
	}
	if peak := c.concurrency(); peak < 2 {
		t.Errorf("peak concurrency was %d: the handshakes went out one at a time", peak)
	}
	// Sequentially this is 30 × 60ms = 1.8s at best. The burst has to be a
	// fraction of that or it is not doing the one thing it is for.
	if elapsed > time.Second {
		t.Errorf("took %s; a burst of six should need a fraction of the 1.8s a single file would", elapsed)
	}
	// The counter is incremented when an attempt is launched, so it matches what
	// the burst decided to spend rather than what the last goroutine got round to.
	if got := s.stats.syns.Load(); got != int64(spent) {
		t.Errorf("counted %d handshakes, spent %d", got, spent)
	}
}

func TestBurstClosesTheConnectionsItDoesNotUse(t *testing.T) {
	// Every handshake is answered, so the burst wins several at once and must hand
	// back exactly one and close the rest. A leak here is a socket per flow.
	c := &censor{}
	s := testServer(c.dial)
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "attempts": 8, "parallel": 8, "attempt_timeout_ms": 100, "retry_budget_ms": 5000
    }`)

	conn, _, err := s.burst(somewhere, tbl)
	if err != nil {
		t.Fatalf("burst: %v", err)
	}

	// The losers are closed on their way out of the goroutine, which happens after
	// burst returns.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		open := 0
		c.mu.Lock()
		handed := append([]*fakeConn(nil), c.handedOut...)
		c.mu.Unlock()
		for _, held := range handed {
			if !held.closed.Load() {
				open++
			}
		}
		if open == 1 {
			conn.Close()
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("more than one connection was still open: the burst leaked what it did not use")
}

func TestBurstStopsWhenTheFarEndAnswers(t *testing.T) {
	// A refusal means the destination is reachable and saying no. Retrying it
	// would only be a slower way to report the same thing.
	c := &censor{refuse: true}
	s := testServer(c.dial)
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "attempts": 96, "parallel": 6, "attempt_timeout_ms": 100, "retry_budget_ms": 5000
    }`)

	_, spent, err := s.burst(somewhere, tbl)
	if err == nil {
		t.Fatal("a refused connection was reported as open")
	}
	if spent > 6 {
		t.Errorf("spent %d handshakes on a destination that refused the first", spent)
	}
	if s.fuses.cool(somewhere, time.Now()) {
		t.Error("a destination that answered was put on the cooldown list")
	}
}

func TestBurstStaysInsideItsBudget(t *testing.T) {
	c := &censor{dropped: 1 << 30, delay: 20 * time.Millisecond}
	s := testServer(c.dial)
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "attempts": 1000, "parallel": 4, "attempt_timeout_ms": 30, "retry_budget_ms": 300
    }`)

	started := time.Now()
	if _, _, err := s.burst(somewhere, tbl); err == nil {
		t.Fatal("a destination that never answers was reported as open")
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Errorf("a 300ms budget took %s to give up", elapsed)
	}
	if spent := c.handshakes(); spent >= 1000 {
		t.Errorf("spent the whole %d-handshake allowance inside a 300ms budget", spent)
	}
}

// ---------------------------------------------------------------------------
// The fuse
// ---------------------------------------------------------------------------

func TestAHopelessDestinationStopsCostingAFullBurst(t *testing.T) {
	c := &censor{dropped: 1 << 30, delay: 5 * time.Millisecond}
	s := testServer(c.dial)
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "attempts": 96, "parallel": 6, "attempt_timeout_ms": 20, "retry_budget_ms": 400,
        "cooldown_ms": 30000, "cool_after": 3
    }`)

	// Three spent budgets to trip it, as configured.
	for round := 1; round <= 3; round++ {
		if _, _, err := s.burst(somewhere, tbl); err == nil {
			t.Fatalf("round %d: reported open", round)
		}
	}
	if !s.fuses.cool(somewhere, time.Now()) {
		t.Fatal("three spent budgets did not cool the destination down")
	}

	// From here a flow gets the short burst: enough to catch a destination that
	// has started answering, and a fraction of the cost. Clients retry a failing
	// address in tight loops, so this is the path taken most often of all.
	before := c.handshakes()
	started := time.Now()
	if _, _, err := s.burst(somewhere, tbl); err == nil {
		t.Fatal("reported open while cooled")
	}
	spent := c.handshakes() - before
	if spent > tbl.coolTries {
		t.Errorf("a cooled destination cost %d handshakes, want at most %d", spent, tbl.coolTries)
	}
	if spent > tbl.tries/4 {
		t.Errorf("a cooled destination cost %d of the %d a full burst spends", spent, tbl.tries)
	}
	// And it gives up quickly, so the client can move on to the next address in
	// its own list instead of waiting out a budget meant for a live destination.
	if elapsed := time.Since(started); elapsed > tbl.budget {
		t.Errorf("a cooled destination took %s to give up, longer than a full budget", elapsed)
	}
	if got := s.stats.cooled.Load(); got != 1 {
		t.Errorf("cooled counter is %d, want 1", got)
	}
}

func TestGoingOnFailingWidensTheInterval(t *testing.T) {
	f := newFuses()
	now := time.Now()
	dst := netip.MustParseAddrPort("91.105.192.100:443")

	f.failed(dst, now, 1, time.Second)
	f.mu.Lock()
	first := f.seen[dst].until
	f.mu.Unlock()

	f.failed(dst, now, 1, time.Second)
	f.mu.Lock()
	second := f.seen[dst].until
	f.mu.Unlock()
	if !second.After(first) {
		t.Error("a second spent budget did not widen the interval")
	}

	// And it stops widening, rather than putting the destination out of reach for
	// the rest of the day.
	for i := 0; i < 40; i++ {
		f.failed(dst, now, 1, time.Second)
	}
	f.mu.Lock()
	last := f.seen[dst].until
	f.mu.Unlock()
	if wait := last.Sub(now); wait > maxCooldown {
		t.Errorf("the interval grew to %s, past the %s ceiling", wait, maxCooldown)
	}
}

func TestADestinationThatAnswersAgainIsForgiven(t *testing.T) {
	c := &censor{dropped: 1 << 30, delay: 5 * time.Millisecond}
	s := testServer(c.dial)
	tbl := testTable(t, `{
        "listen": "10.8.0.1:8646",
        "attempts": 8, "parallel": 4, "attempt_timeout_ms": 20, "retry_budget_ms": 150,
        "cooldown_ms": 30000, "cool_after": 1
    }`)

	if _, _, err := s.burst(somewhere, tbl); err == nil {
		t.Fatal("reported open")
	}
	if !s.fuses.cool(somewhere, time.Now()) {
		t.Fatal("a spent budget did not cool the destination down")
	}

	// The filter stops dropping. The single handshake a cooled destination still
	// gets has to be what notices, or the cooldown would outlive the block.
	c.mu.Lock()
	c.dropped = 0
	c.mu.Unlock()

	conn, _, err := s.burst(somewhere, tbl)
	if err != nil {
		t.Fatalf("a destination that started answering again was not retried: %v", err)
	}
	conn.Close()
	if s.fuses.cool(somewhere, time.Now()) {
		t.Error("a destination that answered is still cooled down")
	}
}

func TestTheCooldownListDoesNotGrowWithoutLimit(t *testing.T) {
	f := newFuses()
	now := time.Now()
	// Expired entries, which is what a censor moving across a range leaves behind.
	for i := 0; i < 5000; i++ {
		dst := netip.AddrPortFrom(netip.AddrFrom4([4]byte{10, byte(i >> 8), byte(i), 1}), 443)
		f.failed(dst, now.Add(-time.Hour), 1, time.Second)
	}
	f.mu.Lock()
	size := len(f.seen)
	f.mu.Unlock()
	if size > 4096 {
		t.Errorf("the cooldown list holds %d entries", size)
	}
}

// ---------------------------------------------------------------------------
// What the node container reads
// ---------------------------------------------------------------------------

func TestSnapshotSaysWhatTheRelayIsDoing(t *testing.T) {
	s := testServer((&censor{}).dial)
	if _, err := s.load(writeConfig(t, `{"listen": "10.8.0.1:8646",
        "map": [{"prefix": "149.154.167.51/32", "v6": "2001:67c:4e8:f002::a"}]}`)); err != nil {
		t.Fatalf("load: %v", err)
	}
	s.stats.viaV6.Add(2)
	s.stats.cooled.Add(3)
	s.stats.fail(os.ErrDeadlineExceeded)

	var got map[string]any
	if err := json.Unmarshal(s.stats.snapshot(), &got); err != nil {
		t.Fatalf("the snapshot is not JSON: %v", err)
	}
	for _, key := range []string{
		"pid", "listen", "prefixes", "open", "accepted", "via_v6", "via_retry",
		"failed", "attempts", "cooled", "rx_bytes", "tx_bytes", "last_error",
	} {
		if _, ok := got[key]; !ok {
			t.Errorf("the snapshot has no %q, so the panel cannot report it", key)
		}
	}
	if got["prefixes"] != float64(1) || got["listen"] != "10.8.0.1:8646" {
		t.Errorf("the snapshot describes a different table: %v", got)
	}
}

func TestReloadRefusesToMoveTheListener(t *testing.T) {
	s := testServer((&censor{}).dial)
	path := writeConfig(t, `{"listen": "10.8.0.1:8646", "map": []}`)
	if _, err := s.load(path); err != nil {
		t.Fatalf("load: %v", err)
	}
	// The listener is bound for the life of the process, so accepting this would
	// leave the relay claiming an address it is not on.
	if err := os.WriteFile(path, []byte(`{"listen": "10.8.0.1:9000", "map": []}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.load(path); err == nil {
		t.Fatal("a reload was allowed to change the listen address")
	}
	if s.current().listen != "10.8.0.1:8646" {
		t.Error("the running table was replaced by one that was refused")
	}
}

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	path := t.TempDir() + "/bypass.json"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}
