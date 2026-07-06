package api

// auth_test.go — POST /api/v1/auth + IsAuthorized middleware
// behaviour (Sprint 5 PR-32, ADV-3).
//
// These tests pin:
//
//   - Login returns 200 + a valid bearer token + expires_in
//     when the body has a non-empty user_id.
//   - Login rejects empty / non-JSON / missing-user_id bodies
//     with 400 (and does NOT emit a token).
//   - Login works WITHOUT an Authorization header (a login
//     endpoint that required a token would be chicken-and-egg).
//   - IsAuthorized accepts a freshly-minted token and stamps
//     the verified subject into the request context.
//   - IsAuthorized rejects missing / non-Bearer / wrong-signature
//     / expired / wrong-issuer / alg=none tokens with 401.
//   - IsAuthorized is NOT applied to /api/v1/auth or to public
//     routes (matrix, operator/lookup).
//   - IsAuthorized IS applied to all protected routes
//     (sessions, telemetry, webrtc, users delete).

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/opene2ee-com/e2ee-app/backend/internal/auth"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// -----------------------------------------------------------------------------
// POST /api/v1/auth
// -----------------------------------------------------------------------------

func TestAuth_Login_HappyPath(t *testing.T) {
	ta := newTestAPI(t)

	body := `{"user_id":"device-abc123"}`
	w := do(t, ta.Handler(), "POST", "/api/v1/auth",
		withAPIHeaders(t, nil), body)

	require.Equal(t, http.StatusOK, w.Code,
		"login must succeed; body=%s", w.Body.String())

	var resp loginResponse
	readJSON(t, w.Body, &resp)

	assert.NotEmpty(t, resp.Token, "token must be present")
	assert.Equal(t, "Bearer", resp.TokenType)
	assert.Equal(t, int(auth.DefaultTokenTTL.Seconds()), resp.ExpiresIn)

	// The minted token must round-trip through VerifyJWT — this
	// is the wire contract the Kong JWT plugin will see.
	claims, err := auth.VerifyJWT(resp.Token, TestJWTSecret)
	require.NoError(t, err)
	assert.Equal(t, "device-abc123", claims.Subject)
	assert.Equal(t, auth.Issuer, claims.Issuer)
	assert.Equal(t, "HS256", headerAlg(t, resp.Token))
}

func TestAuth_Login_RejectsEmptyBody(t *testing.T) {
	ta := newTestAPI(t)
	w := do(t, ta.Handler(), "POST", "/api/v1/auth",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusBadRequest, w.Code)
	assert.NotContains(t, w.Body.String(), "token",
		"a rejected login must NOT emit a token")
}

func TestAuth_Login_RejectsBadJSON(t *testing.T) {
	ta := newTestAPI(t)
	w := do(t, ta.Handler(), "POST", "/api/v1/auth",
		withAPIHeaders(t, nil), "{not valid json")
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestAuth_Login_RejectsEmptyUserID(t *testing.T) {
	ta := newTestAPI(t)
	for _, body := range []string{
		`{}`,
		`{"user_id":""}`,
		`{"user_id":"   "}`,
	} {
		t.Run(body, func(t *testing.T) {
			w := do(t, ta.Handler(), "POST", "/api/v1/auth",
				withAPIHeaders(t, nil), body)
			require.Equal(t, http.StatusBadRequest, w.Code,
				"body=%s must reject; got=%s", body, w.Body.String())
		})
	}
}

// TestAuth_Login_NoAuthorizationRequired — login must work
// even without a bearer token (a login endpoint that requires
// a token is a chicken-and-egg). Specifically we verify that
// sending NO Authorization header succeeds.
func TestAuth_Login_NoAuthorizationRequired(t *testing.T) {
	ta := newTestAPI(t)
	hdr := withoutBearer(nil)
	w := do(t, ta.Handler(), "POST", "/api/v1/auth", hdr, `{"user_id":"x"}`)
	require.Equal(t, http.StatusOK, w.Code,
		"login must not require an Authorization header; got=%s", w.Body.String())
}

// TestAuth_Login_RequiresAPIVersion — like every /api/v1/*,
// /api/v1/auth requires X-API-Version. (Outer middleware, not
// IsAuthorized.)
func TestAuth_Login_RequiresAPIVersion(t *testing.T) {
	ta := newTestAPI(t)
	hdr := map[string]string{"Content-Type": "application/json"}
	w := do(t, ta.Handler(), "POST", "/api/v1/auth", hdr, `{"user_id":"x"}`)
	require.Equal(t, http.StatusBadRequest, w.Code)
}

// -----------------------------------------------------------------------------
// IsAuthorized — failure modes
// -----------------------------------------------------------------------------

func TestIsAuthorized_MissingHeader_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	// Hit a protected route with NO Authorization header.
	hdr := withoutBearer(nil)
	w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code)
	assert.Contains(t, w.Body.String(), `"unauthorized"`)
}

func TestIsAuthorized_NonBearerScheme_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	hdr := withAPIHeaders(t, nil)
	hdr[HeaderAuthorization] = "Basic dXNlcjpwYXNz" // not Bearer
	w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestIsAuthorized_WrongSignature_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	// Mint a token with a DIFFERENT secret.
	wrong, err := auth.IssueJWT("user", time.Hour,
		[]byte("a-totally-different-secret-of-sufficient-length"))
	require.NoError(t, err)
	hdr := withAPIHeaders(t, nil)
	hdr[HeaderAuthorization] = "Bearer " + wrong

	w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestIsAuthorized_ExpiredToken_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	// Hand-craft an already-expired token (signed with TestJWTSecret).
	claims := auth.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    auth.Issuer,
			Subject:   "user",
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC().Add(-2 * time.Hour)),
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(-time.Hour)),
			ID:        "expired-pin",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).
		SignedString(TestJWTSecret)
	require.NoError(t, err)

	hdr := withAPIHeaders(t, nil)
	hdr[HeaderAuthorization] = "Bearer " + tok
	w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestIsAuthorized_ForgedIssuer_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	claims := auth.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "evil-issuer",
			Subject:   "user",
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC()),
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(time.Hour)),
			ID:        "forged-iss-pin",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).
		SignedString(TestJWTSecret)
	require.NoError(t, err)

	hdr := withAPIHeaders(t, nil)
	hdr[HeaderAuthorization] = "Bearer " + tok
	w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestIsAuthorized_AlgNone_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	claims := auth.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    auth.Issuer,
			Subject:   "attacker",
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC()),
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(time.Hour)),
			ID:        "alg-none-pin",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodNone, claims).
		SignedString(jwt.UnsafeAllowNoneSignatureType)
	require.NoError(t, err)

	hdr := withAPIHeaders(t, nil)
	hdr[HeaderAuthorization] = "Bearer " + tok
	w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestIsAuthorized_MalformedToken_Returns401(t *testing.T) {
	ta := newTestAPI(t)
	for _, in := range []string{
		"this-is-not-a-jwt",
		"a.b",
		"a.b.c.d",
	} {
		t.Run(in, func(t *testing.T) {
			hdr := withAPIHeaders(t, nil)
			hdr[HeaderAuthorization] = "Bearer " + in
			w := do(t, ta.Handler(), "POST", "/api/v1/sessions", hdr, "{}")
			require.Equal(t, http.StatusUnauthorized, w.Code)
		})
	}
}

// TestIsAuthorized_HappyPath_StampsContext — when the token is
// valid the middleware must succeed AND stamp the subject into
// the request context. We verify via a custom test handler that
// reads UserIDFromContext. Mounted directly on a one-off mux so
// we don't have to reach all the way through to a real handler.
func TestIsAuthorized_HappyPath_StampsContext(t *testing.T) {
	ta := newTestAPI(t)

	// Wrap the IsAuthorized middleware around a probe handler.
	probe := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		uid := UserIDFromContext(r.Context())
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"uid":"` + uid + `"}`))
	})
	mux := http.NewServeMux()
	mux.Handle("/probe", ta.API.IsAuthorized()(probe))

	hdr := map[string]string{
		HeaderAuthorization: "Bearer " + TestBearerToken(t, "device-abc"),
	}
	w := do(t, mux, "GET", "/probe", hdr, "")
	require.Equal(t, http.StatusOK, w.Code)
	assert.Contains(t, w.Body.String(), `"uid":"device-abc"`,
		"IsAuthorized must stamp the subject into ctx")
}

// -----------------------------------------------------------------------------
// Per-route coverage — IsAuthorized should be wired on every
// protected route, and ABSENT from the public ones.
// -----------------------------------------------------------------------------

// TestIsAuthorized_ProtectedRoutes — every route in the
// JWT-protected subtree returns 401 without a valid token.
//
// The list mirrors router.go's protected subtree. If a future
// contributor adds a new protected route, this test is the
// safety net — they should add the path here and watch the test
// pass.
func TestIsAuthorized_ProtectedRoutes(t *testing.T) {
	ta := newTestAPI(t)
	cases := []struct {
		method string
		path   string
	}{
		{"POST", "/api/v1/sessions"},
		{"GET", "/api/v1/sessions"},
		{"GET", "/api/v1/sessions/00000000-0000-0000-0000-000000000000"},
		{"POST", "/api/v1/sessions/00000000-0000-0000-0000-000000000000/telemetry"},
		{"DELETE", "/api/v1/users/abcdef1234567890abcdef1234567890"},
		{"GET", "/api/v1/webrtc/config"},
		{"POST", "/api/v1/webrtc/offer"},
		{"POST", "/api/v1/webrtc/answer"},
		{"POST", "/api/v1/webrtc/ice"},
	}
	for _, c := range cases {
		t.Run(c.method+" "+c.path, func(t *testing.T) {
			w := do(t, ta.Handler(), c.method, c.path, withoutBearer(nil), "")
			assert.Equal(t, http.StatusUnauthorized, w.Code,
				"%s %s must 401 without a bearer", c.method, c.path)
		})
	}
}

// TestIsAuthorized_PublicRoutes — every public route returns
// its normal status without a bearer (matrix, operator lookup,
// /api/v1/auth login).
func TestIsAuthorized_PublicRoutes(t *testing.T) {
	ta := newTestAPI(t)
	cases := []struct {
		method string
		path   string
		// We check just the prefix of the status — public routes
		// that hit a missing dependency still return 5xx, NOT 401.
		wantNotStatus int
	}{
		{"GET", "/api/v1/matrix", http.StatusUnauthorized},
		{"GET", "/api/v1/operator/lookup?qtype=phone_e164&q=%2B905321234567", http.StatusUnauthorized},
		{"POST", "/api/v1/auth", http.StatusUnauthorized}, // 400 (bad body), not 401
	}
	for _, c := range cases {
		t.Run(c.method+" "+c.path, func(t *testing.T) {
			w := do(t, ta.Handler(), c.method, c.path, withoutBearer(nil), "{}")
			assert.NotEqual(t, c.wantNotStatus, w.Code,
				"%s %s must NOT return 401 (public route); got=%d body=%s",
				c.method, c.path, w.Code, w.Body.String())
		})
	}
}

// -----------------------------------------------------------------------------
// Server-misconfiguration: empty JWT secret must fail closed.
// -----------------------------------------------------------------------------

// TestIsAuthorized_EmptyJWTSecret_AllRequestsRejected — if the
// server is misconfigured with no JWT_SECRET, EVERY protected
// request must be rejected. The login endpoint will also fail
// because IssueJWT returns ErrJWTEmptySecret. This pins the
// "fail closed" posture called out in api.go's Config doc.
func TestIsAuthorized_EmptyJWTSecret_AllRequestsRejected(t *testing.T) {
	store := newFakeStore()
	op := newFakeOperator()
	logger := newFakeLogger()
	mq := NewMemoryMatrixQuerier()

	a, err := New(Config{
		Logger:    logger,
		Sessions:  store,
		Telemetry: store,
		Users:     store,
		Operator:  op,
		Matrix:    mq,
		Devices:   store,
		// JWTSecret deliberately omitted — zero value = empty.
	})
	require.NoError(t, err)

	// Login: 500 because IssueJWT fails with ErrJWTEmptySecret.
	w := do(t, a.Handler(), "POST", "/api/v1/auth",
		withAPIHeaders(t, nil), `{"user_id":"x"}`)
	require.Equal(t, http.StatusInternalServerError, w.Code,
		"login must fail 500 when JWT secret is empty")

	// Protected route: 401 because VerifyJWT rejects empty secret.
	w = do(t, a.Handler(), "POST", "/api/v1/sessions",
		withAPIHeaders(t, nil), "{}")
	require.Equal(t, http.StatusUnauthorized, w.Code,
		"protected route must 401 when JWT secret is empty")
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// headerAlg extracts the `alg` header from a JWT without
// validating the signature. Used by TestAuth_Login_HappyPath
// to pin the alg=HS256 wire format that the Kong JWT plugin
// expects to see.
func headerAlg(t *testing.T, tok string) string {
	t.Helper()
	parser := jwt.NewParser()
	header, _, err := parser.ParseUnverified(tok, &auth.Claims{})
	require.NoError(t, err)
	return header.Method.Alg()
}

// ensure strings is referenced (used in TestIsAuthorized_MalformedToken via the case loop).
var _ = strings.Contains