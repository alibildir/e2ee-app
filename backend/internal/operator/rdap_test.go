// rdap_test.go — unit tests for the RDAP client.
//
// We redirect the bootstrap URL to an httptest.Server and serve a
// canned RDAP JSON body. The wire protocol is the same in
// production; only the dialer differs.
package operator

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// rdapTestServer wires a single httptest server that responds to
// "/ip/<ip>" with the JSON the test specifies.
type rdapTestServer struct {
	*httptest.Server
	hits int32
}

func newRDAPServer(t *testing.T, body string, status int) *rdapTestServer {
	t.Helper()
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		// Both the bootstrap URL and the IP query share the same
		// test server; we just return the canned body for any
		// path. Production splits these across rdap.org → RIR.
		w.Header().Set("Content-Type", "application/rdap+json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(srv.Close)
	return &rdapTestServer{Server: srv, hits: hits}
}

func TestRDAPClient_Lookup_HappyPath(t *testing.T) {
	body := `{
		"handle": "RIPE-NET-1",
		"startAddress": "78.180.0.0",
		"endAddress": "78.181.255.255",
		"country": "TR",
		"name": "Turkcell-Net",
		"type": "DIRECT ALLOCATION"
	}`
	srv := newRDAPServer(t, body, http.StatusOK)
	c, err := NewRDAPClient(RDAPConfig{
		BootstrapURL: srv.URL + "/",
		HTTPTimeout:  2 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewRDAPClient: %v", err)
	}
	ip := netip.MustParseAddr("78.180.1.1")
	info, err := c.Lookup(context.Background(), ip)
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if info.Operator != "RIPE-NET-1" {
		t.Errorf("Operator = %q, want RIPE-NET-1", info.Operator)
	}
	if info.Country != "TR" {
		t.Errorf("Country = %q, want TR", info.Country)
	}
	if info.Source != SourceRDAP {
		t.Errorf("Source = %q, want %q", info.Source, SourceRDAP)
	}
	if info.Confidence != 0.95 {
		t.Errorf("Confidence = %v, want 0.95", info.Confidence)
	}
}

func TestRDAPClient_Lookup_NotFoundIsUnknown(t *testing.T) {
	srv := newRDAPServer(t, "not found", http.StatusNotFound)
	c, _ := NewRDAPClient(RDAPConfig{BootstrapURL: srv.URL + "/", HTTPTimeout: 2 * time.Second})
	_, err := c.Lookup(context.Background(), netip.MustParseAddr("1.2.3.4"))
	if !errors.Is(err, ErrUnknownOperator) {
		t.Errorf("err = %v, want ErrUnknownOperator", err)
	}
}

func TestRDAPClient_Lookup_EmptyAnswerIsUnknown(t *testing.T) {
	// 200 OK with an empty body must still be classified as
	// unknown — the registry said "no record" without a 404.
	srv := newRDAPServer(t, `{}`, http.StatusOK)
	c, _ := NewRDAPClient(RDAPConfig{BootstrapURL: srv.URL + "/", HTTPTimeout: 2 * time.Second})
	_, err := c.Lookup(context.Background(), netip.MustParseAddr("1.2.3.4"))
	if !errors.Is(err, ErrUnknownOperator) {
		t.Errorf("err = %v, want ErrUnknownOperator (empty body)", err)
	}
}

func TestRDAPClient_Lookup_500IsError(t *testing.T) {
	srv := newRDAPServer(t, "boom", http.StatusInternalServerError)
	c, _ := NewRDAPClient(RDAPConfig{BootstrapURL: srv.URL + "/", HTTPTimeout: 2 * time.Second})
	_, err := c.Lookup(context.Background(), netip.MustParseAddr("1.2.3.4"))
	if err == nil {
		t.Fatal("expected error on 500")
	}
	if errors.Is(err, ErrUnknownOperator) {
		t.Errorf("500 must NOT be ErrUnknownOperator, got %v", err)
	}
}

func TestRDAPClient_Lookup_InvalidIP(t *testing.T) {
	c, _ := NewRDAPClient(RDAPConfig{ BootstrapURL: "https://example.invalid" })
	_, err := c.Lookup(context.Background(), netip.Addr{})
	if !errors.Is(err, ErrInvalidInput) {
		t.Errorf("err = %v, want ErrInvalidInput", err)
	}
}

func TestRDAPClient_Lookup_RespectsContextCancellation(t *testing.T) {
	// A server that blocks indefinitely. The client must honour
	// ctx.Done() and abort before the package's default 5s.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)
	c, _ := NewRDAPClient(RDAPConfig{
		BootstrapURL: srv.URL + "/",
		HTTPTimeout:  500 * time.Millisecond,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := c.Lookup(ctx, netip.MustParseAddr("1.2.3.4"))
	if err == nil {
		t.Fatal("expected timeout / context error")
	}
	if time.Since(start) > 2*time.Second {
		t.Errorf("Lookup took %s, expected to abort on ctx deadline", time.Since(start))
	}
}

func TestNewRDAPClient_DefaultBootstrap(t *testing.T) {
	// Empty BootstrapURL → default https://rdap.org/.
	c, err := NewRDAPClient(RDAPConfig{})
	if err != nil {
		t.Fatalf("NewRDAPClient: %v", err)
	}
	if c.cfg.BootstrapURL != defaultRDAPBootstrap {
		t.Errorf("BootstrapURL = %q, want %q", c.cfg.BootstrapURL, defaultRDAPBootstrap)
	}
}

func TestFirstNonEmpty(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{[]string{"", "", "x"}, "x"},
		{[]string{"a", "b", "c"}, "a"},
		{[]string{"", ""}, ""},
		{nil, ""},
	}
	for _, c := range cases {
		got := firstNonEmpty(c.in...)
		if got != c.want {
			t.Errorf("firstNonEmpty(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}

// Smoke test: the full IPReverseAdapter chain with a fake RDAP
// server returns the SourceRDAP answer and masks the IP.
func TestIPReverseAdapter_RDAPHit_MasksIP(t *testing.T) {
	body := `{"handle": "RIPE-NET-1", "country": "TR", "name": "Turkcell-Net"}`
	srv := newRDAPServer(t, body, http.StatusOK)
	rdap, err := NewRDAPClient(RDAPConfig{
		BootstrapURL: srv.URL + "/",
		HTTPTimeout:  2 * time.Second,
	})
	if err != nil {
		t.Fatalf("NewRDAPClient: %v", err)
	}
	a := NewIPReverseAdapterWithDeps(rdap, nil)
	got, err := a.LookupByIP(context.Background(), "78.180.1.1")
	// 78.180.1.1 is in the local ASN table → that path is hit
	// first and we never reach RDAP. Use an IP NOT in the local
	// table.
	got, err = a.LookupByIP(context.Background(), "203.0.113.5")
	if err != nil {
		t.Fatalf("LookupByIP: %v", err)
	}
	if got.Source != SourceRDAP {
		t.Errorf("Source = %q, want %q", got.Source, SourceRDAP)
	}
	if got.QueryValue != MaskIP("203.0.113.5") {
		t.Errorf("QueryValue = %q, want masked %q",
			got.QueryValue, MaskIP("203.0.113.5"))
	}
	if strings.Contains(got.QueryValue, "203.0.113.5") {
		t.Errorf("QueryValue contains raw IP: %q", got.QueryValue)
	}
}
// ---------------------------------------------------------------------------
// Bootstrap discovery retry policy (Sprint 5 PR-30)
// ---------------------------------------------------------------------------

// rdapBootstrapRecorder is an httptest server that captures every
// inbound request so tests can assert the HTTP method, attempt
// count, and per-attempt timing. The status sequence is supplied
// per-test (e.g. first 2 calls return 404, third returns 200) so
// we can exercise the retry policy deterministically.
type rdapBootstrapRecorder struct {
	*httptest.Server
	hits    int32
	methods []string
	statuses []int
	delays  []time.Duration // per-request handler delay
}

func newRDAPBootstrapRecorder(t *testing.T, statuses []int, delays []time.Duration) *rdapBootstrapRecorder {
	t.Helper()
	r := &rdapBootstrapRecorder{
		statuses: statuses,
		delays:   delays,
	}
	r.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		n := atomic.AddInt32(&r.hits, 1)
		r.methods = append(r.methods, req.Method)
		// Apply per-request delay if provided. We don't block the
		// handler thread on its own delay so it can serve the
		// next attempt in parallel; we just measure it via timing.
		if int(n)-1 < len(r.delays) && r.delays[int(n)-1] > 0 {
			time.Sleep(r.delays[int(n)-1])
		}
		idx := int(n) - 1
		if idx >= len(r.statuses) {
			idx = len(r.statuses) - 1
		}
		w.WriteHeader(r.statuses[idx])
	}))
	t.Cleanup(r.Server.Close)
	return r
}

// TestRDAPBootstrap_UsesHEADMethod asserts that the bootstrap
// probe is a HEAD request (not GET), so we don't transfer a
// body we don't need. The IP lookup itself is still a GET
// against the resolved RIR — to exercise that path the test
// server returns 200 on the first HEAD (resolving the final URL
// to itself) and a valid RDAP body on the subsequent GET.
func TestRDAPBootstrap_UsesHEADMethod(t *testing.T) {
	var hits int32
	var methods []string
	body := `{"handle":"RIPE-NET-1","country":"TR","name":"Test-Net"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		methods = append(methods, r.Method)
		switch r.Method {
		case http.MethodHead:
			// Bootstrap probe: respond with 200 directly. We
			// intentionally do NOT redirect — we want the
			// resolved final URL to be THIS server, so the
			// subsequent GET hits our /ip/<ip> handler.
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			w.Header().Set("Content-Type", "application/rdap+json")
			_, _ = io.WriteString(w, body)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	t.Cleanup(srv.Close)

	c, err := NewRDAPClient(RDAPConfig{
		BootstrapURL:     srv.URL + "/",
		HTTPTimeout:      2 * time.Second,
		BootstrapRetries: 3,
	})
	if err != nil {
		t.Fatalf("NewRDAPClient: %v", err)
	}
	_, err = c.Lookup(context.Background(), netip.MustParseAddr("203.0.113.5"))
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if atomic.LoadInt32(&hits) != 2 {
		t.Errorf("hits = %d, want 2 (1x HEAD bootstrap + 1x GET IP)", hits)
	}
	if len(methods) != 2 || methods[0] != http.MethodHead || methods[1] != http.MethodGet {
		t.Errorf("methods = %v, want [HEAD GET]", methods)
	}
}

// TestRDAPBootstrap_RetryOnTransient404 covers the canonical
// retry scenario: rdap.org/ip/<ip> returns 404 on the first
// HEAD attempt (the central delegation hasn't synced yet), then
// 200 on the second HEAD, then a valid body on the IP lookup
// GET. The retry policy must absorb the transient failure.
func TestRDAPBootstrap_RetryOnTransient404(t *testing.T) {
	body := `{"handle":"RIPE-NET-1","country":"TR","name":"Test-Net"}`
	var hits int32
	var methods []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		methods = append(methods, r.Method)
		switch r.Method {
		case http.MethodHead:
			if n == 1 {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			w.Header().Set("Content-Type", "application/rdap+json")
			_, _ = io.WriteString(w, body)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	t.Cleanup(srv.Close)

	c, _ := NewRDAPClient(RDAPConfig{
		BootstrapURL:     srv.URL + "/",
		HTTPTimeout:      2 * time.Second,
		BootstrapRetries: 3,
	})
	info, err := c.Lookup(context.Background(), netip.MustParseAddr("203.0.113.5"))
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if info.Operator != "RIPE-NET-1" {
		t.Errorf("Operator = %q, want RIPE-NET-1", info.Operator)
	}
	if atomic.LoadInt32(&hits) != 3 {
		t.Errorf("hits = %d, want 3 (HEAD 404 + HEAD 200 + GET 200)", hits)
	}
	want := []string{http.MethodHead, http.MethodHead, http.MethodGet}
	if got := methods; len(got) != len(want) {
		t.Errorf("methods length = %d, want %d", len(got), len(want))
	} else {
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("methods[%d] = %q, want %q", i, got[i], want[i])
			}
		}
	}
}

// TestRDAPBootstrap_RetryOnTransient5xx covers the 5xx branch:
// the upstream registry hiccups on the first HEAD call, returns
// 200 on the second. The retry policy must absorb the failure.
func TestRDAPBootstrap_RetryOnTransient5xx(t *testing.T) {
	var hits int32
	var methods []string
	body := `{"handle":"ARIN-NET-1","country":"US","name":"ARIN-Net"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&hits, 1)
		methods = append(methods, r.Method)
		switch r.Method {
		case http.MethodHead:
			if n == 1 {
				w.WriteHeader(http.StatusBadGateway)
				return
			}
			w.WriteHeader(http.StatusOK)
		case http.MethodGet:
			w.Header().Set("Content-Type", "application/rdap+json")
			_, _ = io.WriteString(w, body)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	}))
	t.Cleanup(srv.Close)

	c, _ := NewRDAPClient(RDAPConfig{
		BootstrapURL:     srv.URL + "/",
		HTTPTimeout:      2 * time.Second,
		BootstrapRetries: 3,
	})
	info, err := c.Lookup(context.Background(), netip.MustParseAddr("198.51.100.5"))
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if info.Operator != "ARIN-NET-1" {
		t.Errorf("Operator = %q, want ARIN-NET-1", info.Operator)
	}
	if atomic.LoadInt32(&hits) != 3 {
		t.Errorf("hits = %d, want 3 (HEAD 502 + HEAD 200 + GET 200)", hits)
	}
	want := []string{http.MethodHead, http.MethodHead, http.MethodGet}
	if got := methods; len(got) != len(want) {
		t.Errorf("methods length = %d, want %d", len(got), len(want))
	} else {
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("methods[%d] = %q, want %q", i, got[i], want[i])
			}
		}
	}
}

// TestRDAPBootstrap_ExhaustsRetriesThen404 covers the "give up"
// path: every attempt returns 404. After BootstrapRetries
// attempts the client must return ErrUnknownOperator (the same
// signal a successful 404 lookup would produce), and the
// underlying IP query must NOT be issued.
func TestRDAPBootstrap_ExhaustsRetriesThen404(t *testing.T) {
	var hits int32
	var methods []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		methods = append(methods, r.Method)
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)

	c, _ := NewRDAPClient(RDAPConfig{
		BootstrapURL:     srv.URL + "/",
		HTTPTimeout:      2 * time.Second,
		BootstrapRetries: 3,
	})
	_, err := c.Lookup(context.Background(), netip.MustParseAddr("203.0.113.5"))
	if !errors.Is(err, ErrUnknownOperator) {
		t.Errorf("err = %v, want ErrUnknownOperator", err)
	}
	if got := atomic.LoadInt32(&hits); got != 3 {
		t.Errorf("hits = %d, want 3 (BootstrapRetries attempts)", got)
	}
	for i, m := range methods {
		if m != http.MethodHead {
			t.Errorf("attempt %d method = %q, want HEAD", i+1, m)
		}
	}
}

// TestRDAPBootstrap_Definitive4xxDoesNotRetry covers the "no
// retry" path: a non-404 4xx (e.g. 400, 403) is a definitive
// client error — retrying won't help and would amplify the
// problem. The client must give up after the first attempt.
func TestRDAPBootstrap_Definitive4xxDoesNotRetry(t *testing.T) {
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&hits, 1)
		w.WriteHeader(http.StatusForbidden)
	}))
	t.Cleanup(srv.Close)

	c, _ := NewRDAPClient(RDAPConfig{
		BootstrapURL:     srv.URL + "/",
		HTTPTimeout:      2 * time.Second,
		BootstrapRetries: 3,
	})
	_, err := c.Lookup(context.Background(), netip.MustParseAddr("203.0.113.5"))
	if err == nil {
		t.Fatal("expected error on 403")
	}
	if errors.Is(err, ErrUnknownOperator) {
		t.Errorf("403 must NOT be ErrUnknownOperator, got %v", err)
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Errorf("hits = %d, want 1 (definitive 4xx must NOT retry)", got)
	}
}

// TestRDAPBootstrap_RespectsBackoffSchedule asserts that the
// per-attempt delays match LookupBootstrapBackoffs. We use a
// fast schedule (LookupBootstrapBackoffs is shared state; tests
// swap it temporarily and restore via t.Cleanup) so the test
// itself doesn't take >250ms.
func TestRDAPBootstrap_RespectsBackoffSchedule(t *testing.T) {
	// Stash and override the schedule for a fast test.
	orig := LookupBootstrapBackoffs
	t.Cleanup(func() { LookupBootstrapBackoffs = orig })
	LookupBootstrapBackoffs = []time.Duration{
		0,
		10 * time.Millisecond,
		20 * time.Millisecond,
	}

	var hits int32
	var timestamps []time.Time
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		timestamps = append(timestamps, time.Now())
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)

	c, _ := NewRDAPClient(RDAPConfig{
		BootstrapURL:     srv.URL + "/",
		HTTPTimeout:      2 * time.Second,
		BootstrapRetries: 3,
	})
	_, _ = c.Lookup(context.Background(), netip.MustParseAddr("203.0.113.5"))
	if got := atomic.LoadInt32(&hits); got != 3 {
		t.Fatalf("hits = %d, want 3", got)
	}
	// Attempt 1 → immediate (delay 0).
	// Attempt 2 → 10ms after attempt 1.
	// Attempt 3 → 20ms after attempt 2.
	// We assert approximate bounds to avoid flakiness on slow CI.
	delta12 := timestamps[1].Sub(timestamps[0])
	delta23 := timestamps[2].Sub(timestamps[1])
	if delta12 < 8*time.Millisecond {
		t.Errorf("attempt 2 too soon: %s, want >= 10ms", delta12)
	}
	if delta23 < 18*time.Millisecond {
		t.Errorf("attempt 3 too soon: %s, want >= 20ms", delta23)
	}
}

func TestBackoffFor(t *testing.T) {
	// Boundary cases for the schedule accessor.
	if got := backoffFor(1); got != 0 {
		t.Errorf("backoffFor(1) = %s, want 0", got)
	}
	if got := backoffFor(2); got != LookupBootstrapBackoffs[1] {
		t.Errorf("backoffFor(2) = %s, want %s", got, LookupBootstrapBackoffs[1])
	}
	if got := backoffFor(3); got != LookupBootstrapBackoffs[2] {
		t.Errorf("backoffFor(3) = %s, want %s", got, LookupBootstrapBackoffs[2])
	}
	// Attempt past the end of the schedule clamps to the last entry.
	last := LookupBootstrapBackoffs[len(LookupBootstrapBackoffs)-1]
	if got := backoffFor(99); got != last {
		t.Errorf("backoffFor(99) = %s, want %s (clamp to last)", got, last)
	}
}

// TestLoadLookupBootstrapRetriesFromEnv exercises the env-var
// reader across the documented branches.
func TestLoadLookupBootstrapRetriesFromEnv(t *testing.T) {
	// (a) Unset / empty → default.
	t.Setenv(LookupBootstrapRetriesEnv, "")
	if got := LoadLookupBootstrapRetriesFromEnv(); got != DefaultLookupBootstrapRetries {
		t.Errorf("empty env: got %d, want %d", got, DefaultLookupBootstrapRetries)
	}

	// (b) Whitespace-only → default.
	t.Setenv(LookupBootstrapRetriesEnv, "   ")
	if got := LoadLookupBootstrapRetriesFromEnv(); got != DefaultLookupBootstrapRetries {
		t.Errorf("whitespace env: got %d, want %d", got, DefaultLookupBootstrapRetries)
	}

	// (c) Valid integer → parsed value.
	t.Setenv(LookupBootstrapRetriesEnv, "5")
	if got := LoadLookupBootstrapRetriesFromEnv(); got != 5 {
		t.Errorf("5 env: got %d, want 5", got)
	}

	// (d) Malformed value → fall back to default (graceful).
	t.Setenv(LookupBootstrapRetriesEnv, "not-a-number")
	if got := LoadLookupBootstrapRetriesFromEnv(); got != DefaultLookupBootstrapRetries {
		t.Errorf("malformed env: got %d, want default %d", got, DefaultLookupBootstrapRetries)
	}

	// (e) Zero / negative → fall back to default. A retry count
	// of 0 would defeat the policy.
	t.Setenv(LookupBootstrapRetriesEnv, "0")
	if got := LoadLookupBootstrapRetriesFromEnv(); got != DefaultLookupBootstrapRetries {
		t.Errorf("zero env: got %d, want default %d", got, DefaultLookupBootstrapRetries)
	}
	t.Setenv(LookupBootstrapRetriesEnv, "-1")
	if got := LoadLookupBootstrapRetriesFromEnv(); got != DefaultLookupBootstrapRetries {
		t.Errorf("negative env: got %d, want default %d", got, DefaultLookupBootstrapRetries)
	}
}

// TestDefaultLookupBootstrapRetries pins the canonical default.
// If a future PR changes the constant, this catches it.
func TestDefaultLookupBootstrapRetries(t *testing.T) {
	if DefaultLookupBootstrapRetries != 3 {
		t.Errorf("DefaultLookupBootstrapRetries drifted: %d, want 3", DefaultLookupBootstrapRetries)
	}
	if len(LookupBootstrapBackoffs) < DefaultLookupBootstrapRetries+1 {
		t.Errorf("LookupBootstrapBackoffs has %d entries, want at least %d",
			len(LookupBootstrapBackoffs), DefaultLookupBootstrapRetries+1)
	}
}

// TestNewRDAPClient_DefaultBootstrapRetries ensures the
// constructor fills in the default retry count when the caller
// doesn't supply one (the production code path).
func TestNewRDAPClient_DefaultBootstrapRetries(t *testing.T) {
	c, err := NewRDAPClient(RDAPConfig{BootstrapURL: "https://example.invalid/"})
	if err != nil {
		t.Fatalf("NewRDAPClient: %v", err)
	}
	if c.cfg.BootstrapRetries != DefaultLookupBootstrapRetries {
		t.Errorf("default BootstrapRetries = %d, want %d",
			c.cfg.BootstrapRetries, DefaultLookupBootstrapRetries)
	}
}
