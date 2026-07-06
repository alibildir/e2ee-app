// btk_feed_test.go — unit tests for the BTK MNP feed client.
//
// We exercise the wire protocol against an httptest.Server that
// speaks the BTK pull endpoint contract; the production code path
// is the same — only the dialer differs.
//
// Webhook subscription tests verify the HMAC-SHA256 signature
// scheme, the timestamp skew window, and the replay-protection
// dedupe.
package operator

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// insecureTLS returns a *tls.Config that accepts any server
// certificate. Only for use in unit tests against httptest
// self-signed servers.
func insecureTLS() *tls.Config {
	return &tls.Config{InsecureSkipVerify: true}
}

func newTestBTKServer(t *testing.T, handler http.HandlerFunc) (*httptest.Server, *BTKFeedConfig) {
	t.Helper()
	srv := httptest.NewTLSServer(handler)
	t.Cleanup(srv.Close)
	// httptest TLS gives us a self-signed server cert; configure
	// the client to trust it via InsecureSkipVerify only for the
	// duration of this test.
	cfg := BTKFeedConfig{
		Endpoint:    srv.URL + "/v1/lookup",
		HTTPTimeout: 2 * time.Second,
		UserAgent:   "opene2ee-operator/test",
	}
	return srv, &cfg
}

func TestBTKFeedClient_Lookup_HappyPath(t *testing.T) {
	srv, cfg := newTestBTKServer(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("method = %s, want POST", r.Method)
		}
		body, _ := io.ReadAll(r.Body)
		var req BTKLookupRequest
		if err := json.Unmarshal(body, &req); err != nil {
			t.Errorf("decode req: %v", err)
		}
		if req.MSISDN != "+905320000000" {
			t.Errorf("req.MSISDN = %q, want +905320000000", req.MSISDN)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(BTKLookupResponse{
			MSISDN:       "+905320000000",
			Operator:     "vodafone_tr",
			OperatorName: "Vodafone TR",
			MCC:          "286",
			MNC:          "02",
			Confidence:   0.99,
		})
	})
	cfg.Endpoint = srv.URL + "/v1/lookup"

	// Trust the httptest cert by overriding the transport with
	// the test server's client. Easier: use the cfg HTTPClient
	// field. We don't have one — instead, build the client with
	// an http.Client that skips verification for this test.
	c, err := newTestBTKClientInsecure(*cfg)
	if err != nil {
		t.Fatalf("client: %v", err)
	}
	resp, err := c.Lookup(context.Background(), "+905320000000")
	if err != nil {
		t.Fatalf("Lookup: %v", err)
	}
	if resp.Operator != "vodafone_tr" {
		t.Errorf("Operator = %q, want vodafone_tr", resp.Operator)
	}
	if resp.Confidence != 0.99 {
		t.Errorf("Confidence = %v, want 0.99", resp.Confidence)
	}
}

// newTestBTKClientInsecure constructs a BTKFeedClient that trusts
// the httptest TLS server's self-signed cert. InsecureSkipVerify
// is acceptable only in unit tests.
func newTestBTKClientInsecure(cfg BTKFeedConfig) (*BTKFeedClient, error) {
	if cfg.HTTPTimeout <= 0 {
		cfg.HTTPTimeout = 2 * time.Second
	}
	if cfg.UserAgent == "" {
		cfg.UserAgent = "opene2ee-operator/test"
	}
	tr := &http.Transport{
		TLSClientConfig: insecureTLS(),
	}
	httpClient := &http.Client{
		Timeout:   cfg.HTTPTimeout,
		Transport: tr,
	}
	c, err := NewBTKFeedClient(cfg)
	if err != nil {
		return nil, err
	}
	c.http = httpClient
	return c, nil
}

func TestBTKFeedClient_Lookup_NotFoundIsUnknown(t *testing.T) {
	srv, cfg := newTestBTKServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	cfg.Endpoint = srv.URL + "/v1/lookup"
	c, _ := newTestBTKClientInsecure(*cfg)
	_, err := c.Lookup(context.Background(), "+905320000000")
	if !errors.Is(err, ErrUnknownOperator) {
		t.Errorf("err = %v, want ErrUnknownOperator", err)
	}
}

func TestBTKFeedClient_Lookup_500IsError(t *testing.T) {
	srv, cfg := newTestBTKServer(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("btk backend down"))
	})
	cfg.Endpoint = srv.URL + "/v1/lookup"
	c, _ := newTestBTKClientInsecure(*cfg)
	_, err := c.Lookup(context.Background(), "+905320000000")
	if err == nil {
		t.Fatal("expected error on 500, got nil")
	}
	if errors.Is(err, ErrUnknownOperator) {
		t.Errorf("500 must NOT be classified as ErrUnknownOperator, got %v", err)
	}
}

func TestBTKFeedClient_Lookup_InvalidInput(t *testing.T) {
	c, _ := newTestBTKClientInsecure(BTKFeedConfig{Endpoint: "https://example.invalid"})
	_, err := c.Lookup(context.Background(), "not a phone")
	if !errors.Is(err, ErrInvalidInput) {
		t.Errorf("err = %v, want ErrInvalidInput", err)
	}
}

func TestNewBTKFeedClient_RequiresEndpoint(t *testing.T) {
	if _, err := NewBTKFeedClient(BTKFeedConfig{}); err == nil {
		t.Error("empty Endpoint accepted")
	}
}

func TestNewBTKFeedAdapter_RequiresClient(t *testing.T) {
	if _, err := NewBTKFeedAdapter(nil); err == nil {
		t.Error("nil client accepted")
	}
}

func TestBTKFeedAdapter_LookupByPhone_MasksMSISDN(t *testing.T) {
	srv, cfg := newTestBTKServer(t, func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(BTKLookupResponse{
			MSISDN: "+905320000000", Operator: "turkcell", OperatorName: "Turkcell",
			MCC: "286", MNC: "01", Confidence: 1,
		})
	})
	cfg.Endpoint = srv.URL + "/v1/lookup"
	c, _ := newTestBTKClientInsecure(*cfg)
	a, err := NewBTKFeedAdapter(c)
	if err != nil {
		t.Fatalf("NewBTKFeedAdapter: %v", err)
	}
	info, err := a.LookupByPhone(context.Background(), "+905320000000")
	if err != nil {
		t.Fatalf("LookupByPhone: %v", err)
	}
	// Privacy invariant: the masked MSISDN (not the raw one)
	// must be in QueryValue. ADR-0006.
	if info.QueryValue != MaskPhoneE164("+905320000000") {
		t.Errorf("QueryValue = %q, want masked form %q",
			info.QueryValue, MaskPhoneE164("+905320000000"))
	}
	if strings.Contains(info.QueryValue, "905320000000") {
		t.Errorf("QueryValue still contains raw subscriber digits: %q", info.QueryValue)
	}
	if info.Source != SourceBTKFeed {
		t.Errorf("Source = %q, want %q", info.Source, SourceBTKFeed)
	}
}

func TestBTKFeedAdapter_LookupByIP_ReturnsUnknown(t *testing.T) {
	c, _ := newTestBTKClientInsecure(BTKFeedConfig{Endpoint: "https://example.invalid"})
	a, _ := NewBTKFeedAdapter(c)
	_, err := a.LookupByIP(context.Background(), "8.8.8.8")
	if !errors.Is(err, ErrUnknownOperator) {
		t.Errorf("err = %v, want ErrUnknownOperator", err)
	}
}

func TestClampConfidence(t *testing.T) {
	cases := []struct {
		in, want float64
	}{
		{-0.5, 0},
		{0, 0},
		{0.5, 0.5},
		{1, 1},
		{1.5, 1},
	}
	for _, c := range cases {
		got := clampConfidence(c.in)
		if got != c.want {
			t.Errorf("clampConfidence(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// Webhook subscription
// ---------------------------------------------------------------------------

func TestBTKWebhook_Verify_HappyPath(t *testing.T) {
	var called int32
	handler := func(_ context.Context, ev BTKWebhookEvent) error {
		atomic.AddInt32(&called, 1)
		if ev.MSISDN != "+905320000000" {
			t.Errorf("ev.MSISDN = %q, want +905320000000", ev.MSISDN)
		}
		return nil
	}
	sub, err := NewBTKWebhookSubscription([]byte("s3cr3t"), handler)
	if err != nil {
		t.Fatalf("NewBTKWebhookSubscription: %v", err)
	}
	body, _ := json.Marshal(map[string]string{"msisdn": "+905320000000", "ported_to": "vodafone_tr"})
	sig := sub.Sign(body)
	ts := time.Now().UTC().Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body, sig, ts); err != nil {
		t.Errorf("Verify: %v", err)
	}
	if atomic.LoadInt32(&called) != 1 {
		t.Errorf("handler called %d times, want 1", called)
	}
	// Replay of the same event MUST be deduped.
	if err := sub.Verify(context.Background(), body, sig, ts); err != nil {
		t.Errorf("Verify replay: %v", err)
	}
	if atomic.LoadInt32(&called) != 1 {
		t.Errorf("handler called %d times after replay, want 1 (dedupe failed)", called)
	}
}

func TestBTKWebhook_Verify_BadSignature(t *testing.T) {
	sub, _ := NewBTKWebhookSubscription([]byte("s3cr3t"), func(_ context.Context, _ BTKWebhookEvent) error { return nil })
	body := []byte(`{"msisdn":"+905320000000"}`)
	if err := sub.Verify(context.Background(), body, "deadbeef", time.Now().UTC().Format(time.RFC3339)); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("err = %v, want ErrInvalidInput", err)
	}
}

func TestBTKWebhook_Verify_StaleTimestamp(t *testing.T) {
	sub, _ := NewBTKWebhookSubscription([]byte("s3cr3t"), func(_ context.Context, _ BTKWebhookEvent) error { return nil })
	body := []byte(`{}`)
	sig := sub.Sign(body)
	// 10 minutes ago — well outside the 5-minute skew window.
	stale := time.Now().UTC().Add(-10 * time.Minute).Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body, sig, stale); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("err = %v, want ErrInvalidInput (stale)", err)
	}
}

func TestBTKWebhook_Verify_BadTimestamp(t *testing.T) {
	sub, _ := NewBTKWebhookSubscription([]byte("s3cr3t"), func(_ context.Context, _ BTKWebhookEvent) error { return nil })
	body := []byte(`{}`)
	sig := sub.Sign(body)
	if err := sub.Verify(context.Background(), body, sig, "not-a-timestamp"); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("err = %v, want ErrInvalidInput (bad ts)", err)
	}
}

func TestBTKWebhook_RequiresSecretAndHandler(t *testing.T) {
	if _, err := NewBTKWebhookSubscription(nil, func(_ context.Context, _ BTKWebhookEvent) error { return nil }); err == nil {
		t.Error("nil secret accepted")
	}
	if _, err := NewBTKWebhookSubscription([]byte("x"), nil); err == nil {
		t.Error("nil handler accepted")
	}
}

// TestBTKWebhook_DefaultMaxSkew documents the default skew window
// applied by NewBTKWebhookSubscription. If a future PR changes the
// default (or removes the field), this catches it.
func TestBTKWebhook_DefaultMaxSkew(t *testing.T) {
	sub, err := NewBTKWebhookSubscription([]byte("s3cr3t"), func(_ context.Context, _ BTKWebhookEvent) error { return nil })
	if err != nil {
		t.Fatalf("NewBTKWebhookSubscription: %v", err)
	}
	if sub.MaxSkew != DefaultBTKMaxSkew {
		t.Errorf("default MaxSkew = %s, want %s", sub.MaxSkew, DefaultBTKMaxSkew)
	}
	if DefaultBTKMaxSkew != 5*time.Minute {
		t.Errorf("DefaultBTKMaxSkew drifted: %s, want 5m", DefaultBTKMaxSkew)
	}
}

// TestBTKWebhook_NonDefaultMaxSkew exercises the tunable MaxSkew
// field. We construct a subscription with a tighter 30-second
// window and verify:
//   - a 10-second-old timestamp is accepted (within window).
//   - a 60-second-old timestamp is rejected as stale (ErrInvalidInput).
//   - a future-leaning timestamp beyond the window is also rejected
//     (replay protection covers both directions).
func TestBTKWebhook_NonDefaultMaxSkew(t *testing.T) {
	sub, err := NewBTKWebhookSubscription([]byte("s3cr3t"), func(_ context.Context, _ BTKWebhookEvent) error { return nil })
	if err != nil {
		t.Fatalf("NewBTKWebhookSubscription: %v", err)
	}
	sub.MaxSkew = 30 * time.Second

	body := []byte(`{"msisdn":"+905320000000"}`)
	sig := sub.Sign(body)

	// (a) 10s in the past → well within the 30s window.
	within := time.Now().UTC().Add(-10 * time.Second).Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body, sig, within); err != nil {
		t.Errorf("Verify (within window): %v, want nil", err)
	}

	// (b) 60s in the past → outside the 30s window. The handler
	// would be called for case (a), so we use a fresh sig/body for
	// case (b) to avoid the replay-dedupe short-circuit.
	body2 := []byte(`{"msisdn":"+905320000001"}`)
	sig2 := sub.Sign(body2)
	stale := time.Now().UTC().Add(-60 * time.Second).Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body2, sig2, stale); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("Verify (60s old): err = %v, want ErrInvalidInput", err)
	}

	// (c) 60s in the future → also outside the 30s window. Use a
	// unique body so we don't trip the replay dedupe.
	body3 := []byte(`{"msisdn":"+905320000002"}`)
	sig3 := sub.Sign(body3)
	future := time.Now().UTC().Add(60 * time.Second).Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body3, sig3, future); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("Verify (60s future): err = %v, want ErrInvalidInput", err)
	}
}

// TestLoadBTKMaxSkewFromEnv exercises the env-var reader across
// the documented branches. The test sets and clears the env var
// with t.Setenv so the change is automatically reverted.
func TestLoadBTKMaxSkewFromEnv(t *testing.T) {
	// (a) Unset / empty → default.
	t.Setenv(BTKMaxSkewEnv, "")
	if got := LoadBTKMaxSkewFromEnv(); got != DefaultBTKMaxSkew {
		t.Errorf("empty env: got %s, want %s", got, DefaultBTKMaxSkew)
	}

	// (b) Whitespace-only → default.
	t.Setenv(BTKMaxSkewEnv, "   ")
	if got := LoadBTKMaxSkewFromEnv(); got != DefaultBTKMaxSkew {
		t.Errorf("whitespace env: got %s, want %s", got, DefaultBTKMaxSkew)
	}

	// (c) Valid duration string → parsed value.
	t.Setenv(BTKMaxSkewEnv, "30s")
	if got := LoadBTKMaxSkewFromEnv(); got != 30*time.Second {
		t.Errorf("30s env: got %s, want 30s", got)
	}

	// (d) Larger window via hour unit.
	t.Setenv(BTKMaxSkewEnv, "1h")
	if got := LoadBTKMaxSkewFromEnv(); got != time.Hour {
		t.Errorf("1h env: got %s, want 1h", got)
	}

	// (e) Malformed value → fall back to default (graceful
	// degradation, not a fatal config error).
	t.Setenv(BTKMaxSkewEnv, "not-a-duration")
	if got := LoadBTKMaxSkewFromEnv(); got != DefaultBTKMaxSkew {
		t.Errorf("malformed env: got %s, want default %s", got, DefaultBTKMaxSkew)
	}

	// (f) Zero / negative durations → fall back to default. A
	// zero-duration MaxSkew would defeat replay protection, so
	// the loader rejects the env value rather than passing it
	// through.
	t.Setenv(BTKMaxSkewEnv, "0s")
	if got := LoadBTKMaxSkewFromEnv(); got != DefaultBTKMaxSkew {
		t.Errorf("zero env: got %s, want default %s", got, DefaultBTKMaxSkew)
	}
	t.Setenv(BTKMaxSkewEnv, "-5m")
	if got := LoadBTKMaxSkewFromEnv(); got != DefaultBTKMaxSkew {
		t.Errorf("negative env: got %s, want default %s", got, DefaultBTKMaxSkew)
	}
}

// TestBTKWebhook_MaxSkewFromEnv_RoundTrip wires the env reader to
// the subscription's MaxSkew field end-to-end. This is the path
// main() will use at startup; documenting it in a test prevents
// the helper and the field from drifting apart.
func TestBTKWebhook_MaxSkewFromEnv_RoundTrip(t *testing.T) {
	t.Setenv(BTKMaxSkewEnv, "20s")
	sub, err := NewBTKWebhookSubscription([]byte("s3cr3t"), func(_ context.Context, _ BTKWebhookEvent) error { return nil })
	if err != nil {
		t.Fatalf("NewBTKWebhookSubscription: %v", err)
	}
	sub.MaxSkew = LoadBTKMaxSkewFromEnv()
	if sub.MaxSkew != 20*time.Second {
		t.Fatalf("MaxSkew after env apply = %s, want 20s", sub.MaxSkew)
	}

	// 5s in the past → accepted under 20s window.
	body := []byte(`{"msisdn":"+905321111111"}`)
	sig := sub.Sign(body)
	within := time.Now().UTC().Add(-5 * time.Second).Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body, sig, within); err != nil {
		t.Errorf("Verify (5s old, 20s window): %v, want nil", err)
	}

	// 60s in the past → rejected under 20s window.
	body2 := []byte(`{"msisdn":"+905321111112"}`)
	sig2 := sub.Sign(body2)
	stale := time.Now().UTC().Add(-60 * time.Second).Format(time.RFC3339)
	if err := sub.Verify(context.Background(), body2, sig2, stale); !errors.Is(err, ErrInvalidInput) {
		t.Errorf("Verify (60s old, 20s window): err = %v, want ErrInvalidInput", err)
	}
}