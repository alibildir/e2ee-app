package api

// users_test.go — DELETE /api/v1/users/{device_id_hash} handler tests.
//
// Pins the AUTHZ contract introduced in Sprint 6 PR-37
// (hand-off from cyber-security review, finding AUTHZ-1 /
// STRIDE-6-04). Before PR-37 the handler accepted any
// device_id_hash path argument from any authenticated
// caller, which meant a holder of a JWT could trigger a
// KVKK delete against any other user's salted device hash.
// The fix closes the destructive endpoint on `sub == path
// hash`. This file pins:
//   - happy path: subject == path hash → 200
//   - happy path: store.DeleteUser called exactly once with
//     the path hash (no cross-device side-effects)
//   - cross-device attempt: subject != path hash → 403
//   - cross-device attempt: store.DeleteUser NEVER called
//     (the destructive handler MUST short-circuit before
//     touching storage)
//   - cross-device attempt: warning logged with err_kind=authz
//   - bad path: malformed device_id_hash → 400
//   - bad path: missing bearer → 401 (IsAuthorized still gates)
//   - DeleteUser error: store fails → 500, no hook fired
//   - hook error: store OK but hook fails → still 200 (logged
//     warn; sweepers uphold the 7-day SLA)
//   - hash boundary: 16 and 64 char hashes accepted

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/url"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/opene2ee-com/e2ee-app/backend/internal/auth"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// sampleDeviceHash returns a deterministic 32-char lowercase
// hex string for tests. Matches auth.TruncateHexLen so the
// handler's isValidDeviceHash accepts it.
func sampleDeviceHash(seed byte) string {
	hex := "0123456789abcdef"[seed>>4 : seed>>4+1]
	hex += "0123456789abcdef"[seed&0x0f : (seed&0x0f)+1]
	s := ""
	for len(s) < 32 {
		s += hex
	}
	return s[:32]
}

// uniqueHashes returns N distinct device hashes for tests
// that need two different actors (e.g. cross-device attempt).
func uniqueHashes(n int) []string {
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = sampleDeviceHash(byte(i + 1))
	}
	return out
}

// decodeErrorBody is a small helper for asserting on the
// canonical ErrorBody envelope.
func decodeErrorBody(t *testing.T, body []byte) ErrorBody {
	t.Helper()
	var eb ErrorBody
	if err := jsonDecode(bytes.NewReader(body), &eb); err != nil {
		t.Fatalf("decode ErrorBody: %v body=%s", err, string(body))
	}
	return eb
}

// mintExpiredToken mints an HS256 JWT with the given subject
// whose `exp` claim is one hour in the past. Used to assert
// that IsAuthorized rejects an expired token before the
// AUTHZ check runs.
func mintExpiredToken(t *testing.T, subject string) string {
	t.Helper()
	claims := auth.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    auth.Issuer,
			Subject:   subject,
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(-1 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC().Add(-2 * time.Hour)),
			ID:        "expired-test-token",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).
		SignedString(TestJWTSecret)
	require.NoError(t, err)
	return tok
}

// deleteUserHookFunc is the signature Config.DeleteUserHook expects.
type deleteUserHookFunc func(ctx context.Context, deviceIDHash string) error

// withDeleteUserHook installs a test-controlled hook on the
// API. Returns a cleanup func the caller should defer.
func withDeleteUserHook(ta *testAPI, hook deleteUserHookFunc) func() {
	ta.API.deps.Cfg.DeleteUserHook = hook
	return func() {
		ta.API.deps.Cfg.DeleteUserHook = nil
	}
}

// TestDeleteUser_HappyPath_SubMatchesHash — when the JWT
// subject equals the path hash, the handler must succeed
// AND the store must be called exactly once with that hash.
func TestDeleteUser_HappyPath_SubMatchesHash(t *testing.T) {
	ta := newTestAPI(t)
	caller := uniqueHashes(1)[0]

	headers := map[string]string{
		HeaderAPIVersion:    APIVersion,
		"Content-Type":      "application/json",
		HeaderAuthorization: "Bearer " + TestBearerToken(t, caller),
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+caller, headers, "")
	require.Equal(t, http.StatusOK, w.Code, "body=%s", w.Body.String())

	ta.Store.mu.Lock()
	calls := append([]string(nil), ta.Store.DeletedHashes...)
	ta.Store.mu.Unlock()
	require.Equal(t, []string{caller}, calls, "DeleteUser must be called once with the path hash")

	var resp deleteUserResponse
	readJSON(t, w.Body, &resp)
	assert.True(t, resp.Deleted)
	assert.Equal(t, caller, resp.DeviceIDHash)
}

// TestDeleteUser_CrossDeviceAttempt_Forbidden — the core
// cyber-security finding (AUTHZ-1 / STRIDE-6-04). A logged-in
// device with sub=hashA MUST NOT be able to delete hashB.
//
// This is the regression test that prevents PR-37 from being
// silently undone. If a future refactor removes the
// sub == path check, this test will fail with the store
// being called on hashB and a 200 response — both wrong.
func TestDeleteUser_CrossDeviceAttempt_Forbidden(t *testing.T) {
	ta := newTestAPI(t)
	hashes := uniqueHashes(2)
	caller := hashes[0] // JWT sub
	target := hashes[1] // path hash — NOT the caller's

	headers := map[string]string{
		HeaderAPIVersion:    APIVersion,
		"Content-Type":      "application/json",
		HeaderAuthorization: "Bearer " + TestBearerToken(t, caller),
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+target, headers, "")
	require.Equal(t, http.StatusForbidden, w.Code, "body=%s", w.Body.String())

	// Body MUST use the canonical ErrorCode = forbidden.
	eb := decodeErrorBody(t, w.Body.Bytes())
	assert.Equal(t, CodeForbidden, eb.Code, "error code MUST be 'forbidden'")

	// Store MUST NOT have been called — the destructive handler
	// short-circuits before touching storage. This is the
	// most important assertion in the whole PR-37 fix: a
	// cross-device attempt cannot leak through to the DB layer.
	ta.Store.mu.Lock()
	calls := append([]string(nil), ta.Store.DeletedHashes...)
	ta.Store.mu.Unlock()
	assert.Empty(t, calls, "DeleteUser MUST NOT be called on a cross-device attempt; got=%v", calls)

	// A warn log line with err_kind=authz MUST be emitted so
	// an operator can spot repeated cross-device attempts
	// (e.g. a stolen token probing for sibling hashes).
	warn := ta.Logger.EntriesByLevel("warn")
	require.NotEmpty(t, warn, "cross-device attempt must emit a warn log")
	var found bool
	for _, e := range warn {
		if e.Args["err_kind"] == "authz" {
			found = true
			break
		}
	}
	assert.True(t, found, "warn log must carry err_kind=authz; got=%+v", warn)
}

// TestDeleteUser_BadHashShape — isValidDeviceHash must reject
// any path argument that is not 16-64 lowercase hex characters.
// We do NOT want phone-number-shaped or unicode-looking strings
// to slip into the device_id_hash column.
func TestDeleteUser_BadHashShape(t *testing.T) {
	ta := newTestAPI(t)
	// We use url.PathEscape for non-URL-safe characters so the
	// HTTP request line stays parseable. The handler receives
	// the URL-decoded value via chi.URLParam and isValidDeviceHash
	// runs on that decoded string. The handler-level validation
	// is what we are pinning here, not transport-level parsing.
	cases := []struct {
		name string
		hash string // raw value that the handler will receive after URL decoding
	}{
		{"too_short", "abc123"},
		{"non_hex_uppercase", "ABCDEF1234567890ABCDEF1234567890"},
		{"non_hex_phone", "+905321234567"},
		{"non_hex_unicode", "abc🙂1234567890abcdef12345678"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			headers := map[string]string{
				HeaderAPIVersion:    APIVersion,
				"Content-Type":      "application/json",
				HeaderAuthorization: "Bearer " + TestBearerToken(t, "any-user"),
			}
			w := do(t, ta.Handler(), "DELETE",
				"/api/v1/users/"+url.PathEscape(c.hash), headers, "")
			assert.Equal(t, http.StatusBadRequest, w.Code, "body=%s", w.Body.String())
			eb := decodeErrorBody(t, w.Body.Bytes())
			assert.Equal(t, CodeBadRequest, eb.Code)

			// Store MUST NOT have been called.
			ta.Store.mu.Lock()
			calls := append([]string(nil), ta.Store.DeletedHashes...)
			ta.Store.mu.Unlock()
			assert.Empty(t, calls, "DeleteUser MUST NOT be called on a bad-shape hash")
		})
	}
}

// TestDeleteUser_MissingBearer_Returns401 — IsAuthorized still
// gates the route. The AUTHZ-1 fix is layered ON TOP of the
// existing JWT check, not replacing it.
func TestDeleteUser_MissingBearer_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	hash := sampleDeviceHash(0x05)
	headers := map[string]string{
		HeaderAPIVersion: APIVersion,
		"Content-Type":   "application/json",
		// No Authorization header.
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+hash, headers, "")
	require.Equal(t, http.StatusUnauthorized, w.Code)

	ta.Store.mu.Lock()
	calls := append([]string(nil), ta.Store.DeletedHashes...)
	ta.Store.mu.Unlock()
	assert.Empty(t, calls, "DeleteUser MUST NOT be called without a bearer")
}

// TestDeleteUser_ExpiredToken_Returns401 — expired JWT must
// fail at IsAuthorized before the AUTHZ check runs.
func TestDeleteUser_ExpiredToken_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	hash := sampleDeviceHash(0x06)
	expiredTok := mintExpiredToken(t, hash)
	headers := map[string]string{
		HeaderAPIVersion:    APIVersion,
		"Content-Type":      "application/json",
		HeaderAuthorization: "Bearer " + expiredTok,
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+hash, headers, "")
	require.Equal(t, http.StatusUnauthorized, w.Code)

	ta.Store.mu.Lock()
	calls := append([]string(nil), ta.Store.DeletedHashes...)
	ta.Store.mu.Unlock()
	assert.Empty(t, calls, "DeleteUser MUST NOT be called with an expired token")
}

// TestDeleteUser_StoreError_Returns500 — if the relational
// delete fails, the handler MUST surface 500 and MUST NOT
// fire the Redis-side hook (otherwise the hook sees a state
// the user can never reach).
func TestDeleteUser_StoreError_Returns500(t *testing.T) {
	ta := newTestAPI(t)
	hash := sampleDeviceHash(0x07)
	ta.Store.mu.Lock()
	ta.Store.DeleteUserErr = errors.New("simulated db failure")
	ta.Store.mu.Unlock()

	var hookCalled int
	var hookMu sync.Mutex
	cleanup := withDeleteUserHook(ta, func(_ context.Context, _ string) error {
		hookMu.Lock()
		defer hookMu.Unlock()
		hookCalled++
		return nil
	})
	defer cleanup()

	headers := map[string]string{
		HeaderAPIVersion:    APIVersion,
		"Content-Type":      "application/json",
		HeaderAuthorization: "Bearer " + TestBearerToken(t, hash),
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+hash, headers, "")
	require.Equal(t, http.StatusInternalServerError, w.Code)

	// Hook counter MUST be zero — the handler aborts before
	// touching Redis when the relational delete fails.
	hookMu.Lock()
	c := hookCalled
	hookMu.Unlock()
	assert.Equal(t, 0, c, "hook must NOT fire when the relational delete fails")

	// An error log line with err_kind=db MUST be emitted.
	errLogs := ta.Logger.EntriesByLevel("error")
	require.NotEmpty(t, errLogs)
	var found bool
	for _, e := range errLogs {
		if e.Args["err_kind"] == "db" {
			found = true
			break
		}
	}
	assert.True(t, found, "error log must carry err_kind=db; got=%+v", errLogs)

	// Reset for subsequent subtests.
	ta.Store.mu.Lock()
	ta.Store.DeleteUserErr = nil
	ta.Store.mu.Unlock()
}

// TestDeleteUser_HookFailure_Still200 — if the relational
// delete succeeds but the Redis-side hook fails, the user
// still gets 200 (the right-to-erasure was exercised). The
// 7-day SLA is upheld by the periodic sweeper.
func TestDeleteUser_HookFailure_Still200(t *testing.T) {
	ta := newTestAPI(t)
	hash := sampleDeviceHash(0x08)

	var hookCalled int
	var hookMu sync.Mutex
	cleanup := withDeleteUserHook(ta, func(_ context.Context, _ string) error {
		hookMu.Lock()
		defer hookMu.Unlock()
		hookCalled++
		return errors.New("simulated hook failure")
	})
	defer cleanup()

	headers := map[string]string{
		HeaderAPIVersion:    APIVersion,
		"Content-Type":      "application/json",
		HeaderAuthorization: "Bearer " + TestBearerToken(t, hash),
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+hash, headers, "")
	require.Equal(t, http.StatusOK, w.Code, "body=%s", w.Body.String())

	hookMu.Lock()
	c := hookCalled
	hookMu.Unlock()
	assert.Equal(t, 1, c, "hook must fire exactly once after the relational delete succeeds")

	warn := ta.Logger.EntriesByLevel("warn")
	var found bool
	for _, e := range warn {
		if e.Args["err_kind"] == "hook" {
			found = true
			break
		}
	}
	assert.True(t, found, "hook failure must log err_kind=hook")
}

// TestDeleteUser_HashBoundary — exact 16-char and 64-char
// device_id_hash values are accepted (matches the lower /
// upper bounds in isValidDeviceHash).
func TestDeleteUser_HashBoundary(t *testing.T) {
	ta := newTestAPI(t)
	cases := []struct {
		name string
		hash string
	}{
		{"16_chars", "0123456789abcdef"}, // exactly the lower bound
		{"64_chars", "0123456789abcdef" + "0123456789abcdef" + "0123456789abcdef" + "0123456789abcdef"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			headers := map[string]string{
				HeaderAPIVersion:    APIVersion,
				"Content-Type":      "application/json",
				HeaderAuthorization: "Bearer " + TestBearerToken(t, c.hash),
			}
			w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+c.hash, headers, "")
			require.Equal(t, http.StatusOK, w.Code, "body=%s", w.Body.String())
		})
	}
}

// TestDeleteUser_NoCrossDeviceSideEffects — when a cross-device
// attempt is made, the target device's row MUST NOT be
// removed from the in-memory store. This is a stricter form
// of the cross-device test: it explicitly verifies the target
// hash is still present in the store map after the attempt.
func TestDeleteUser_NoCrossDeviceSideEffects(t *testing.T) {
	ta := newTestAPI(t)
	hashes := uniqueHashes(2)
	caller := hashes[0]
	target := hashes[1]

	// Pre-seed the store with a fake device row for `target`.
	ta.Store.mu.Lock()
	ta.Store.Devices[target] = fakeDevice{
		Hash:      target,
		PublicKey: []byte{0x01, 0x02, 0x03},
		FP:        "fingerprint-for-target",
	}
	ta.Store.mu.Unlock()

	headers := map[string]string{
		HeaderAPIVersion:    APIVersion,
		"Content-Type":      "application/json",
		HeaderAuthorization: "Bearer " + TestBearerToken(t, caller),
	}
	w := do(t, ta.Handler(), "DELETE", "/api/v1/users/"+target, headers, "")
	require.Equal(t, http.StatusForbidden, w.Code)

	ta.Store.mu.Lock()
	_, stillThere := ta.Store.Devices[target]
	ta.Store.mu.Unlock()
	assert.True(t, stillThere, "target device row MUST remain in store after a cross-device attempt")
}