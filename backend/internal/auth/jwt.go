// jwt.go — HS256-signed JWT issuance + verification.
//
// ADV-3 (Sprint 2 hotfix deferred to Sprint 5 PR-32) wires this
// helper into the OpenE2EE backend AND the Kong JWT plugin. The
// contract is:
//
//   - Issuer signs the JWT with a shared HS256 secret (the
//     JWT_SECRET env var, read by both the Go backend and the
//     Kong gateway via docker-compose).
//   - The Kong JWT plugin in `infra/kong/kong.yml` is configured
//     with `algorithm: HS256`, `secret_is_base64: false` and the
//     SAME shared secret. The plugin validates the signature
//     before the request reaches the Go backend; the IsAuthorized
//     middleware (in package api) is the defence-in-depth check
//     for direct-backend calls and for unit tests.
//
// CLAIMS (Sprint 5 PR-32 — preliminary, ADV-3 only):
//
//   - sub:   user_id (string). For Sprint 5 we use the device_id_hash
//            (the salted SHA-256 hex already in use across the
//            REST surface) so the JWT subject round-trips with
//            the rest of the API without a separate user table.
//   - iss:   "opene2ee-backend". Hard-coded so a forged token
//            with the same secret but a different iss gets
//            rejected by VerifyJWT.
//   - iat:   issued-at, unix seconds.
//   - exp:   expiry, unix seconds. iat + ttl.
//   - jti:   unique token id (16 random bytes hex) — anti-replay
//            hook for a future deny-list; harmless to include
//            now because VerifyJWT does not consult a deny-list.
//
// NOT IN SCOPE for ADV-3 (Sprint 5 PR-32):
//
//   - Refresh-token / rotate-secret flow (Sprint 6+).
//   - Revoke list / jti deny-list (Sprint 6+).
//   - Audience claim (we have one logical issuer, no audience
//     routing yet).
//
// SECURITY NOTES (ADR-0006-compatible posture):
//
//   - The raw device UUID v7 must NEVER appear in a JWT — only
//     the device_id_hash (the salted SHA-256) is used as the
//     subject. A token logged in clear text therefore cannot
//     be cross-referenced with a phone number or operator.
//   - The HS256 secret is provided by the caller (NOT loaded
//     from the package — that lets unit tests pass synthetic
//     secrets without polluting the global env).
//   - All error returns are sentinel-wrapped so a future caller
//     can branch on errors.Is(err, ErrJWTSignatureInvalid)
//     without parsing strings.
package auth

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Issuer is the value placed in the `iss` claim on every token we
// mint, and the value VerifyJWT requires on incoming tokens.
// Hard-coded so a forge with a different iss fails fast.
const Issuer = "opene2ee-backend"

// DefaultTokenTTL is the TTL IssueJWT falls back to when the
// caller passes zero. 1 hour matches a typical session-cookie
// lifetime and is short enough that a stolen token has limited
// blast radius; the matrix queries / sessions handlers are
// stateless enough that re-issuing is cheap.
const DefaultTokenTTL = 1 * time.Hour

// Sentinel errors. Wrap-friendly — VerifyJWT returns
// fmt.Errorf("%w: ...", ErrJWTSignatureInvalid, ...) so callers
// can use errors.Is without parsing strings.
var (
	// ErrJWTEmptySecret is returned when IssueJWT / VerifyJWT are
	// called with an empty secret. An empty HS256 secret is a
	// "sign with nothing" configuration error, NOT a validation
	// failure — we surface it as a distinct sentinel so the
	// caller (typically startup wiring) can fix it before the
	// server accepts any request.
	ErrJWTEmptySecret = errors.New("auth: empty jwt secret")

	// ErrJWTEmptyUser is returned by IssueJWT when the subject is
	// empty / whitespace. An empty subject would mint a token
	// with no accountability — refuse it.
	ErrJWTEmptyUser = errors.New("auth: empty user id")

	// ErrJWTInvalidTTL is returned when the caller passes a
	// non-positive ttl. A zero-second token is not "valid
	// immediately"; it is "expired immediately". Reject it at
	// issuance so a caller cannot accidentally produce a token
	// Kong will reject (and so VerifyJWT's `exp` is always in
	// the future).
	ErrJWTInvalidTTL = errors.New("auth: non-positive ttl")

	// ErrJWTInvalidClaims is returned by VerifyJWT when the
	// `iss` claim is wrong, the `exp`/`nbf` checks fail, or any
	// other claim-level validation fails (NOT a signature
	// failure — for that, see ErrJWTSignatureInvalid).
	ErrJWTInvalidClaims = errors.New("auth: invalid claims")

	// ErrJWTSignatureInvalid is returned by VerifyJWT when the
	// signature does not verify against the supplied secret.
	// Distinct from ErrJWTInvalidClaims so a caller can
	// distinguish "wrong secret" from "token expired" in
	// metrics / structured logs.
	ErrJWTSignatureInvalid = errors.New("auth: signature invalid")

	// ErrJWTInvalidToken is returned by VerifyJWT when the
	// input does not parse as a JWT at all (malformed base64,
	// wrong number of segments, etc.).
	ErrJWTInvalidToken = errors.New("auth: malformed token")
)

// Claims is the JWT payload we mint and verify. We use the
// stdlib RegisteredClaims for the standard fields (iss, sub, exp,
// iat, jti) and add nothing OpenE2EE-specific on top — ADV-3 is
// the JWT-issuance plumbing; richer claims land in Sprint 6.
//
// JSON tags are deliberately lower-case (`sub`, `iss`, ...)
// matching RFC 7519 §4.1. Do not change them.
type Claims struct {
	jwt.RegisteredClaims
}

// IssueJWT signs a JWT for the given user id with the given
// HS256 secret. ttl controls the expiry; pass 0 to use
// DefaultTokenTTL (1 hour).
//
// Returns the compact-serialised JWT (header.payload.signature)
// on success; an error wrapped around one of the sentinel
// errors above on failure.
//
// The function is intentionally side-effect-free — no global
// clock, no logger, no package-level state. Callers (cmd/server
// or a unit test) inject the secret and the ttl. This keeps the
// helper trivial to test and trivial to compose into a future
// JWT-rotation flow.
func IssueJWT(userID string, ttl time.Duration, secret []byte) (string, error) {
	if len(secret) == 0 {
		return "", ErrJWTEmptySecret
	}
	userID = trimSpaces(userID)
	if userID == "" {
		return "", ErrJWTEmptyUser
	}
	if ttl <= 0 {
		ttl = DefaultTokenTTL
	}

	now := time.Now().UTC()
	jti, err := newJTI()
	if err != nil {
		return "", fmt.Errorf("auth: mint jti: %w", err)
	}

	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    Issuer,
			Subject:   userID,
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
			ID:        jti,
		},
	}
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := tok.SignedString(secret)
	if err != nil {
		return "", fmt.Errorf("auth: sign jwt: %w", err)
	}
	return signed, nil
}

// VerifyJWT parses + validates the token against the supplied
// HS256 secret. On success it returns the Claims; on failure it
// returns one of the sentinel errors above (wrapped for
// fmt.Errorf %w).
//
// Verification rules (mirrors Kong's JWT plugin default
// behaviour so a token valid here is also valid at the gateway):
//
//   - Algorithm MUST be HS256. Any other `alg` (including the
//     literal "none") is rejected — preventing the classic
//     "alg=none" downgrade attack.
//   - Signature must verify against the supplied secret.
//   - `iss` must equal Issuer.
//   - `exp` must be in the future (jwt-go enforces this by
//     default; we keep the default).
//   - `iat` is sanity-checked but not strictly enforced — clock
//     skew across the gateway and the Go backend is allowed up
//     to the standard jwt-go leeway.
//
// Errors are wrapped so callers can use errors.Is. The
// underlying error message from jwt-go is preserved so a
// structured log can still record the failure mode without
// needing a per-case switch.
func VerifyJWT(tokenString string, secret []byte) (*Claims, error) {
	if len(secret) == 0 {
		return nil, ErrJWTEmptySecret
	}
	if tokenString == "" {
		return nil, fmt.Errorf("%w: empty token", ErrJWTInvalidToken)
	}

	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Name}),
	)
	claims := &Claims{}
	_, err := parser.ParseWithClaims(tokenString, claims, func(t *jwt.Token) (any, error) {
		// Defence-in-depth — WithValidMethods already gates on
		// the alg, but re-checking here means a future refactor
		// that drops WithValidMethods does not silently open an
		// "alg=none" hole.
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("%w: unexpected signing method %q",
				ErrJWTSignatureInvalid, t.Header["alg"])
		}
		return secret, nil
	})
	if err != nil {
		switch {
		case errors.Is(err, jwt.ErrTokenSignatureInvalid):
			return nil, fmt.Errorf("%w: %v", ErrJWTSignatureInvalid, err)
		case errors.Is(err, jwt.ErrTokenExpired),
			errors.Is(err, jwt.ErrTokenNotValidYet),
			errors.Is(err, jwt.ErrTokenInvalidIssuer),
			errors.Is(err, jwt.ErrTokenInvalidClaims):
			return nil, fmt.Errorf("%w: %v", ErrJWTInvalidClaims, err)
		default:
			// Malformed token, missing segments, bad base64 —
			// jwt-go returns these as ErrTokenMalformed or
			// untyped errors. Bucket them under ErrJWTInvalidToken.
			return nil, fmt.Errorf("%w: %v", ErrJWTInvalidToken, err)
		}
	}

	// Double-check the issuer even though jwt-go's parser already
	// validates it — explicit beats implicit, and the field is
	// read by the access-log middleware.
	if claims.Issuer != Issuer {
		return nil, fmt.Errorf("%w: iss=%q expected %q",
			ErrJWTInvalidClaims, claims.Issuer, Issuer)
	}
	return claims, nil
}

// trimSpaces is a tiny local copy of strings.TrimSpace so we
// don't import strings for one call. (Also lets us centralise the
// "whitespace = empty" rule.)
func trimSpaces(s string) string {
	start, end := 0, len(s)
	for start < end {
		if s[start] == ' ' || s[start] == '\t' || s[start] == '\n' || s[start] == '\r' {
			start++
			continue
		}
		break
	}
	for end > start {
		if s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\n' || s[end-1] == '\r' {
			end--
			continue
		}
		break
	}
	return s[start:end]
}

// newJTI returns 16 random bytes hex-encoded (32 chars). Used as
// the JWT ID. crypto/rand failures are vanishingly rare on a
// healthy OS; we surface them as a wrapped error so a cold-start
// with a broken /dev/urandom is caught at startup, not silently
// minted as a zero jti.
func newJTI() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("rand.Read: %w", err)
	}
	return hex.EncodeToString(b[:]), nil
}