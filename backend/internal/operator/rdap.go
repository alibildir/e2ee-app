// rdap.go — RDAP (Registration Data Access Protocol) client.
//
// RDAP is the IETF-standard HTTP-based replacement for whois,
// defined in RFCs 7480-7485. Each Regional Internet Registry
// (RIR) publishes its own RDAP endpoint; the IANA bootstrap
// file at https://rdap.org/ maps an IP block to the right
// RIR's RDAP server.
//
// Sprint 3 (PR-23) wires RDAP as the PRIMARY live source for IP
// reverse DNS, ahead of whois and ahead of the local ASN table.
//
// PRIVACY (ADR-0006 §Veri Minimizasyonu): RDAP responses may carry
// abuse / registrant emails. We DO NOT propagate those fields
// to OperatorInfo — only the operator / country / ASN fields. The
// raw IP is masked (mask.go) before being placed in cache or
// returned to the REST handler.
package operator

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"strings"
	"time"
)

// defaultRDAPBootstrap is the IANA bootstrap URL that maps CIDR
// ranges to the authoritative RDAP server for the registry that
// allocated the block. It is exposed as a var (not a const) so
// tests can redirect it to httptest.
var defaultRDAPBootstrap = "https://rdap.org/"

// RDAPConfig configures an RDAPClient. Only BootstrapURL is
// required for the default behaviour; the other fields are for
// tests and advanced deployments.
type RDAPConfig struct {
	// BootstrapURL is the IANA RDAP bootstrap URL. Defaults to
	// https://rdap.org/.
	BootstrapURL string

	// HTTPTimeout caps a single request. Default 5s.
	HTTPTimeout time.Duration

	// HTTPClient overrides the default *http.Client. Tests inject
	// one backed by httptest.Server.
	HTTPClient *http.Client

	// UserAgent sent on every request. Default "opene2ee-operator/1.0".
	UserAgent string

	// BootstrapRetries is the number of attempts the bootstrap
	// discovery makes on a transient failure (network error or
	// 404) before giving up. Default 3 (DefaultLookupBootstrapRetries).
	// Each attempt is preceded by LookupBootstrapBackoffs[i]
	// (50ms / 200ms / 1s); the cumulative worst-case wait is
	// well under HTTPTimeout so callers don't notice the retry.
	BootstrapRetries int
}

// RDAPClient performs RDAP IP-network lookups.
//
// The zero value is NOT usable — call NewRDAPClient.
type RDAPClient struct {
	cfg     RDAPConfig
	http    *http.Client
	now     func() time.Time
}

// NewRDAPClient validates cfg and returns a usable client.
// Returns an error when BootstrapURL is empty.
func NewRDAPClient(cfg RDAPConfig) (*RDAPClient, error) {
	if cfg.BootstrapURL == "" {
		cfg.BootstrapURL = defaultRDAPBootstrap
	}
	if cfg.HTTPTimeout <= 0 {
		cfg.HTTPTimeout = 5 * time.Second
	}
	if cfg.UserAgent == "" {
		cfg.UserAgent = "opene2ee-operator/1.0"
	}
	if cfg.BootstrapRetries <= 0 {
		cfg.BootstrapRetries = DefaultLookupBootstrapRetries
	}
	var httpClient *http.Client
	if cfg.HTTPClient != nil {
		httpClient = cfg.HTTPClient
	} else {
		httpClient = &http.Client{Timeout: cfg.HTTPTimeout}
	}
	return &RDAPClient{cfg: cfg, http: httpClient, now: time.Now}, nil
}

// rdapBootstrap is the IANA bootstrap response shape — a map
// from service tag to the list of RDAP base URLs. We only need
// the "ip" entry.
type rdapBootstrap struct {
	IP  []string `json:"ip"`
}

// rdapIPResponse is the subset of RFC 7483 we parse. Fields we
// don't use (entities, events, notices, etc.) are ignored.
type rdapIPResponse struct {
	Handle     string `json:"handle"`     // RIR-specific handle
	StartAddress string `json:"startAddress"` // RFC 7483 §5
	EndAddress   string `json:"endAddress"`
	Country     string `json:"country"`
	Name        string `json:"name"`
	Type        string `json:"type"`
	// The "entities" array can carry abuse / registrant contacts.
	// We deliberately do NOT extract it (ADR-0006 privacy).
}

// Lookup resolves a single IP through the bootstrap → RIR chain.
//
// Returns:
//   - (*OperatorInfo, nil) on success
//   - (nil, ErrUnknownOperator) when no RIR has a record for this IP
//     (the bootstrap has no matching service entry, OR every RDAP
//     server returned 404)
//   - (nil, err) for any other error (network, decode, bad IP)
//
// Source is set to SourceRDAP.
func (c *RDAPClient) Lookup(ctx context.Context, ip netip.Addr) (*OperatorInfo, error) {
	if !ip.IsValid() {
		return nil, fmt.Errorf("rdap: invalid IP: %w", ErrInvalidInput)
	}
	// Discover the RDAP server via the bootstrap. We pass the IP
	// itself as the "prefix" — IANA returns the matching service
	// entry.
	base, err := c.bootstrapServer(ctx, ip)
	if err != nil {
		if errors.Is(err, ErrUnknownOperator) {
			return nil, ErrUnknownOperator
		}
		return nil, fmt.Errorf("rdap: bootstrap: %w", err)
	}
	url := strings.TrimRight(base, "/") + "/ip/" + ip.String()
	body, err := c.doGET(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("rdap: %s: %w", url, err)
	}
	var resp rdapIPResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("rdap: decode: %w", err)
	}
	if resp.Name == "" && resp.Handle == "" {
		// Empty answer → treat as unknown.
		return nil, ErrUnknownOperator
	}
	qt := QueryIPv4
	if ip.Is6() && !ip.Is4In6() {
		qt = QueryIPv6
	}
	info := &OperatorInfo{
		QueryType:    qt,
		QueryValue:   "", // filled by the adapter (masked)
		Operator:     firstNonEmpty(resp.Handle, resp.Name),
		OperatorName: resp.Name,
		Country:      resp.Country,
		Source:       SourceRDAP,
		Confidence:   0.95,
		Timestamp:    c.now().UTC(),
	}
	if info.OperatorName == "" {
		info.OperatorName = info.Operator
	}
	return info, nil
}

// bootstrapServer issues an HTTP HEAD to rdap.org/ip/<ip>. The
// rdap.org redirector returns a 302 to the authoritative RIR for
// the block; we only need the redirect target (Location), so HEAD
// is sufficient and avoids transferring the response body. The
// http.Client follows the redirect transparently and updates
// req.URL, so we read resp.Request.URL to discover the RIR.
//
// RETRY POLICY (Sprint 5 PR-30):
//
// The first probe for a newly allocated IP block can transiently
// 404 — rdap.org's central delegation table lags registry
// allocations by seconds-to-minutes. To absorb that race we retry
// with exponential backoff (50ms / 200ms / 1s). Network errors
// and 5xx are also retried; ErrUnknownOperator from a definitive
// 404 (after all retries) is the only "give up immediately" path.
// The schedule is exposed as LookupBootstrapBackoffs and the
// retry count as BootstrapRetries (default
// DefaultLookupBootstrapRetries=3).
func (c *RDAPClient) bootstrapServer(ctx context.Context, ip netip.Addr) (string, error) {
	maxAttempts := c.cfg.BootstrapRetries
	if maxAttempts <= 0 {
		maxAttempts = DefaultLookupBootstrapRetries
	}
	url := c.cfg.BootstrapURL + "ip/" + ip.String()
	var lastErr error
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if attempt > 1 {
			// Backoff before retry. LookupBootstrapBackoffs[0]
			// is 0 (immediate first attempt); subsequent
			// attempts use the schedule.
			delay := backoffFor(attempt)
			if delay > 0 {
				select {
				case <-ctx.Done():
					return "", fmt.Errorf("rdap: bootstrap: %w", ctx.Err())
				case <-time.After(delay):
				}
			}
		}
		base, retry, err := c.bootstrapServerOnce(ctx, url)
		if err == nil {
			return base, nil
		}
		lastErr = err
		if !retry {
			// Definitive answer (e.g. ErrUnknownOperator on a
			// non-transient 404, or a malformed URL). Don't
			// waste retries.
			return "", err
		}
	}
	return "", fmt.Errorf("rdap: bootstrap: gave up after %d attempts: %w", maxAttempts, lastErr)
}

// bootstrapServerOnce performs a single HEAD probe against url,
// following redirects, and returns the base URL of the redirect
// target. The boolean return is `retry`: true when the failure
// is transient (network error, 5xx, 404) and the caller should
// try again; false when the failure is definitive (bad URL,
// context cancelled, 4xx other than 404).
func (c *RDAPClient) bootstrapServerOnce(ctx context.Context, url string) (string, bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodHead, url, nil)
	if err != nil {
		return "", false, fmt.Errorf("rdap: bootstrap request: %w", err)
	}
	req.Header.Set("User-Agent", c.cfg.UserAgent)
	req.Header.Set("Accept", "application/rdap+json, application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		// Network / context error — transient, worth retrying
		// unless the context is cancelled.
		if ctx.Err() != nil {
			return "", false, fmt.Errorf("rdap: bootstrap: %w", ctx.Err())
		}
		return "", true, fmt.Errorf("rdap: bootstrap http: %w", err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotFound:
		// rdap.org doesn't know about this IP yet — retry.
		return "", true, ErrUnknownOperator
	case resp.StatusCode >= 500:
		// Upstream registry hiccup — retry.
		return "", true, fmt.Errorf("rdap: bootstrap http %d", resp.StatusCode)
	case resp.StatusCode < 200 || resp.StatusCode >= 300:
		// 4xx other than 404 (e.g. 400, 403) — definitive, no retry.
		return "", false, fmt.Errorf("rdap: bootstrap http %d", resp.StatusCode)
	}
	final := resp.Request.URL
	if final == nil {
		return "", false, errors.New("rdap: bootstrap: no final URL")
	}
	base := final.Scheme + "://" + final.Host
	if i := strings.Index(final.Path, "/ip/"); i >= 0 {
		base += final.Path[:i]
	} else if final.Path != "" {
		base += "/"
	}
	return base, false, nil
}

// backoffFor returns the delay to wait BEFORE the given attempt
// number (1-indexed). LookupBootstrapBackoffs[0] is 0 so attempt 1
// fires immediately; attempt 2 waits 50ms, attempt 3 waits 200ms,
// etc. Attempts past the end of the schedule fall back to the
// last entry so the policy is bounded.
func backoffFor(attempt int) time.Duration {
	if attempt <= 1 {
		return 0
	}
	idx := attempt - 1
	if idx >= len(LookupBootstrapBackoffs) {
		idx = len(LookupBootstrapBackoffs) - 1
	}
	return LookupBootstrapBackoffs[idx]
}

// doGET performs an HTTP GET against url and returns the body
// bytes (capped at 1 MiB — RDAP IP responses are tiny).
func (c *RDAPClient) doGET(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", c.cfg.UserAgent)
	req.Header.Set("Accept", "application/rdap+json, application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrUnknownOperator
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("rdap: http %d: %s", resp.StatusCode, string(raw))
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20))
}

// firstNonEmpty returns the first non-empty string among the
// arguments. Used to pick the best "operator" label from a
// RDAP response (which may have Name, Handle, or neither).
func firstNonEmpty(s ...string) string {
	for _, x := range s {
		if x != "" {
			return x
		}
	}
	return ""
}