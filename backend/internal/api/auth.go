package api

// auth.go — POST /api/v1/auth (login) + IsAuthorized middleware.
//
// SCOPE (Sprint 5 PR-32, ADV-3):
//
// This handler is PRELIMINARY. Its only job for ADV-3 is to
// prove the JWT issuance ↔ Kong JWT plugin contract end-to-end:
//
//   - Client posts {user_id: "..."} to /api/v1/auth.
//   - Handler issues a JWT with sub=user_id and a 1h TTL using
//     the same HS256 secret Kong validates against.
//   - Client includes that token in Authorization: Bearer ...
//     on subsequent requests to a protected route.
//   - Kong's JWT plugin validates the token at the gateway
//     (primary defence) and forwards the request to the backend
//     with the X-Consumer-* headers.
//   - The IsAuthorized middleware on protected backend routes
//     is defence-in-depth — it re-validates the token in case
//     Kong is bypassed (local dev, integration tests, future
//     internal services). It also stamps the verified subject
//     into the request context so handlers can read it without
//     re-parsing the Authorization header.
//
// PRIVACY (ADR-0006):
//
//   - The handler NEVER logs the raw user_id (the request body
//     is not logged by the access-log middleware, by package
//     policy). The token itself is also not logged.
//   - For ADV-3 we accept ANY user_id — there's no Users table
//     yet (that's Sprint 6+ per ADR-0006). When the user table
//     lands, replace the stub `lookupUser` step with a real
//     password / credential check. Until then, the handler
//     exists only to make the JWT wire contract observable.
//
// SECURITY POSTURE:
//
//   - We require X-API-Version on the login route too (it's
//     inside the /api/v1 subtree that already enforces it).
//   - Rate-limit middleware is in front of login too (100 req/min
//     per device_id_hash). A flood of login attempts is bounded.
//   - The handler returns a generic 401 with no detail on
//     failure — a probing attacker should not learn whether
//     the user_id "looks valid".
//   - The JWT TTL is short (1 hour). A stolen token has
//     limited blast radius. Refresh-token / rotate-secret flow
//     is deferred to Sprint 6+.

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/opene2ee-com/e2ee-app/backend/internal/auth"
)

// HeaderAuthorization is the standard HTTP header that carries
// the bearer token. Lower-cased constant so tests and log
// output reference the same spelling.
const HeaderAuthorization = "Authorization"

// bearerPrefix is the "Bearer " scheme prefix we expect on the
// Authorization header. RFC 6750 §2.1.
const bearerPrefix = "Bearer "

// loginRequest is the trimmed input shape for POST /api/v1/auth.
// user_id is the only field ADV-3 cares about; future revs add
// `password`, `device_fingerprint`, etc.
type loginRequest struct {
	UserID string `json:"user_id"`
}

// loginResponse is the success body. We deliberately return
// only the token + its expiry — never echo the user_id back, so
// a log line that captures the response body can't reconstruct
// the (already salted) identifier.
type loginResponse struct {
	Token     string `json:"token"`
	TokenType string `json:"token_type"` // "Bearer"
	ExpiresIn int    `json:"expires_in"` // seconds until exp
}

// authLoginTTL is the TTL the login handler stamps on the
// minted JWT. 1h matches auth.DefaultTokenTTL but is kept as
// a named constant so a future change to one does not silently
// drag the other.
const authLoginTTL = 1 * time.Hour

// handleLogin is POST /api/v1/auth.
//
// Request body (JSON):
//
//	{"user_id": "..."}     // required
//
// Successful response (200):
//
//	{
//	  "token":      "eyJhbGciOi...",
//	  "token_type": "Bearer",
//	  "expires_in": 3600
//	}
//
// Failure modes:
//   - 400 bad_request — body not JSON, or user_id empty.
//   - 401 unauthorized — generic catch-all so a probing
//     attacker cannot distinguish "user not found" from
//     "secret misconfigured" from "user_id rejected".
//   - 500 internal_error — IssueJWT failed (e.g. misconfigured
//     server-side JWT_SECRET).
func (a *API) handleLogin() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Bound the body read — 1 KB is comfortably above the
		// largest legitimate user_id (the salted device hash is
		// 32 hex chars) and well below the MaxBytesMiddleware
		// 64 KB ceiling.
		body, err := io.ReadAll(io.LimitReader(r.Body, 1024))
		if err != nil {
			writeBadRequest(w, "Failed to read request body.")
			return
		}
		if len(body) == 0 {
			writeBadRequest(w, "Request body must be a JSON object with a user_id field.")
			return
		}

		var req loginRequest
		if err := json.Unmarshal(body, &req); err != nil {
			writeBadRequest(w, "Request body must be a JSON object with a user_id field.")
			return
		}
		if strings.TrimSpace(req.UserID) == "" {
			writeBadRequest(w, "user_id is required.")
			return
		}

		// (1) ADV-3 stub: there is no user table yet. We accept
		// any non-empty user_id and mint a JWT for it. When the
		// Users table lands (Sprint 6+), this is where the real
		// password / credential check happens.

		// (2) Issue the JWT.
		tok, err := auth.IssueJWT(req.UserID, authLoginTTL, a.jwtSecret)
		if err != nil {
			// IssueJWT returns ErrJWTEmptySecret if the server
			// is misconfigured. Surface as 500 with a generic
			// message; do NOT leak the underlying error to the
			// client.
			a.deps.Cfg.Logger.Error("login: issue jwt failed",
				"err_kind", classifyJWTErr(err),
			)
			writeInternal(w)
			return
		}

		writeJSON(w, http.StatusOK, loginResponse{
			Token:     tok,
			TokenType: "Bearer",
			ExpiresIn: int(authLoginTTL.Seconds()),
		})
	}
}

// -----------------------------------------------------------------------------
// IsAuthorized middleware
// -----------------------------------------------------------------------------

// ctxKeyUserID is the request-context key under which the
// verified JWT subject is stored. Handlers can pull it via
// UserIDFromContext.
const ctxKeyUserID ctxKey = 100

// UserIDFromContext returns the verified subject (sub claim) of
// the JWT that authenticated this request. Returns "" when the
// middleware did not run on this request — handlers behind
// IsAuthorized can rely on a non-empty value; handlers outside
// it (e.g. /healthz) must NOT read it.
func UserIDFromContext(ctx context.Context) string {
	if v := ctx.Value(ctxKeyUserID); v != nil {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

// IsAuthorized returns a chi middleware that validates the
// Authorization: Bearer <jwt> header against the API's
// configured JWT secret. On success the verified subject is
// stored in the request context (UserIDFromContext). On failure
// the middleware short-circuits with a 401.
//
// IsAuthorized is defence-in-depth: Kong's JWT plugin is the
// primary auth gate, but direct-backend callers (local dev,
// integration tests, internal services) still need a check.
//
// Behaviour:
//   - Missing or non-Bearer Authorization header → 401.
//   - Token signature wrong / expired / alg=none / wrong iss → 401.
//   - On success → request continues, subject stamped into
//     context. The token itself is NOT echoed in any header
//     (we don't want a downstream proxy logging it).
func (a *API) IsAuthorized() func(http.Handler) http.Handler {
	secret := a.jwtSecret
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			raw := r.Header.Get(HeaderAuthorization)
			if raw == "" || !strings.HasPrefix(raw, bearerPrefix) {
				writeUnauthorized(w, "missing bearer token")
				return
			}
			tok := strings.TrimSpace(raw[len(bearerPrefix):])
			if tok == "" {
				writeUnauthorized(w, "missing bearer token")
				return
			}
			claims, err := auth.VerifyJWT(tok, secret)
			if err != nil {
				// Log the failure mode (but never the token)
				// so an operator can distinguish a flood of
				// forged tokens from a flood of expired ones.
				a.deps.Cfg.Logger.Warn("jwt verify failed",
					"err_kind", classifyJWTErr(err),
				)
				writeUnauthorized(w, "invalid bearer token")
				return
			}
			ctx := context.WithValue(r.Context(), ctxKeyUserID, claims.Subject)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// classifyJWTErr maps an auth.* sentinel to a short label
// suitable for an "err_kind" log field. We deliberately do NOT
// include the underlying jwt-go error message in the log —
// that can carry byte sequences from a forged token.
func classifyJWTErr(err error) string {
	switch {
	case errors.Is(err, auth.ErrJWTEmptySecret):
		return "empty_secret"
	case errors.Is(err, auth.ErrJWTSignatureInvalid):
		return "signature_invalid"
	case errors.Is(err, auth.ErrJWTInvalidClaims):
		return "invalid_claims"
	case errors.Is(err, auth.ErrJWTInvalidToken):
		return "malformed_token"
	default:
		return "unknown"
	}
}

// writeUnauthorized emits a 401 with the canonical ErrorBody.
// We deliberately use a single generic message ("..." is
// intentionally vague — see auth.go doc on security posture).
func writeUnauthorized(w http.ResponseWriter, msg string) {
	writeError(w, http.StatusUnauthorized, ErrorBody{
		Code:    ErrorCode("unauthorized"),
		Message: msg,
	})
}