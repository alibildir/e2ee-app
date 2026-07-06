// jwt_test.go — known-answer + invariant tests for IssueJWT /
// VerifyJWT. Pins the wire format so the Kong JWT plugin and
// the Go backend agree on:
//
//   - alg = HS256
//   - iss = "opene2ee-backend"
//   - sub = the user id we passed to IssueJWT
//   - iat + ttl = exp
//   - jti is a 32-char hex string (16 random bytes)
//   - "alg=none" downgrade attack is rejected
//   - signature fails closed on a wrong secret
//   - exp check fails closed on an expired token
//   - iss check fails closed on a forged issuer
package auth

import (
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// testSecret is the shared secret used by every test below. It
// is intentionally long enough to look like a production secret
// (32 bytes) so any future length-based code path is exercised.
var testSecret = []byte("opene2ee-jwt-test-secret-32-bytes-min!")

// -----------------------------------------------------------------------------
// IssueJWT — happy path + invariants
// -----------------------------------------------------------------------------

// TestIssueJWT_BasicShape confirms the compact form has the
// three JWT segments separated by '.' and that the header
// decodes to HS256. This is the wire contract the Kong plugin
// will see — pin it.
func TestIssueJWT_BasicShape(t *testing.T) {
	tok, err := IssueJWT("user-1234", time.Minute, testSecret)
	require.NoError(t, err)

	parts := strings.Split(tok, ".")
	require.Len(t, parts, 3, "JWT must have header.payload.signature segments")

	parser := jwt.NewParser(jwt.WithValidMethods([]string{"HS256"}))
	claims := &Claims{}
	_, _, err = parser.ParseUnverified(tok, claims)
	require.NoError(t, err)
	assert.Equal(t, "HS256", claims.AlgorithmOrEmpty(tok), "alg must be HS256")
	assert.Equal(t, Issuer, claims.Issuer)
	assert.Equal(t, "user-1234", claims.Subject)
	assert.NotEmpty(t, claims.ID, "jti must be present")
	assert.Len(t, claims.ID, 32, "jti must be 16 random bytes hex (32 chars)")
}

// TestIssueJWT_TTLApplied confirms that a non-zero ttl is
// reflected in the exp claim (within a small clock tolerance).
func TestIssueJWT_TTLApplied(t *testing.T) {
	before := time.Now().UTC()
	tok, err := IssueJWT("user", 5*time.Minute, testSecret)
	require.NoError(t, err)

	claims, err := VerifyJWT(tok, testSecret)
	require.NoError(t, err)
	require.NotNil(t, claims.ExpiresAt, "exp must be set")

	delta := claims.ExpiresAt.Time.Sub(before)
	assert.InDelta(t, 5*time.Minute, delta, float64(2*time.Second),
		"exp must be approximately iat + ttl (got delta=%s)", delta)
}

// TestIssueJWT_ZeroTTL_DefaultsToOneHour exercises the
// "ttl <= 0 → DefaultTokenTTL" fallback. We check the exp
// delta against DefaultTokenTTL (1 hour).
func TestIssueJWT_ZeroTTL_DefaultsToOneHour(t *testing.T) {
	before := time.Now().UTC()
	tok, err := IssueJWT("user", 0, testSecret)
	require.NoError(t, err)

	claims, err := VerifyJWT(tok, testSecret)
	require.NoError(t, err)
	delta := claims.ExpiresAt.Time.Sub(before)
	assert.InDelta(t, DefaultTokenTTL, delta, float64(2*time.Second),
		"zero ttl must default to DefaultTokenTTL")
}

// TestIssueJWT_NegativeTTL_DefaultsToOneHour — a negative ttl
// is treated as "use default" too (a zero-second token would
// already be expired).
func TestIssueJWT_NegativeTTL_DefaultsToOneHour(t *testing.T) {
	before := time.Now().UTC()
	tok, err := IssueJWT("user", -5*time.Minute, testSecret)
	require.NoError(t, err)

	claims, err := VerifyJWT(tok, testSecret)
	require.NoError(t, err)
	delta := claims.ExpiresAt.Time.Sub(before)
	assert.InDelta(t, DefaultTokenTTL, delta, float64(2*time.Second))
}

// TestIssueJWT_RejectsEmptySecret — an empty HS256 secret is a
// configuration error; we refuse it at issuance.
func TestIssueJWT_RejectsEmptySecret(t *testing.T) {
	_, err := IssueJWT("user", time.Minute, nil)
	require.ErrorIs(t, err, ErrJWTEmptySecret)
	_, err = IssueJWT("user", time.Minute, []byte{})
	require.ErrorIs(t, err, ErrJWTEmptySecret)
}

// TestIssueJWT_RejectsEmptyUser — an empty subject mints a
// token with no accountability; refuse it.
func TestIssueJWT_RejectsEmptyUser(t *testing.T) {
	for _, sub := range []string{"", " ", "\t", "\n", "  \t  "} {
		_, err := IssueJWT(sub, time.Minute, testSecret)
		require.ErrorIs(t, err, ErrJWTEmptyUser, "user=%q must reject", sub)
	}
}

// TestIssueJWT_UniqueJTI — two consecutive issuances must
// produce different jti values (16 random bytes each).
func TestIssueJWT_UniqueJTI(t *testing.T) {
	a, err := IssueJWT("user", time.Minute, testSecret)
	require.NoError(t, err)
	b, err := IssueJWT("user", time.Minute, testSecret)
	require.NoError(t, err)

	ca, err := VerifyJWT(a, testSecret)
	require.NoError(t, err)
	cb, err := VerifyJWT(b, testSecret)
	require.NoError(t, err)

	assert.NotEqual(t, ca.ID, cb.ID, "jti must be unique per token")
}

// -----------------------------------------------------------------------------
// VerifyJWT — round-trip + negative paths
// -----------------------------------------------------------------------------

// TestVerifyJWT_RoundTrip — Issue then Verify, claims survive
// intact.
func TestVerifyJWT_RoundTrip(t *testing.T) {
	tok, err := IssueJWT("device-hash-abc123", time.Minute, testSecret)
	require.NoError(t, err)

	claims, err := VerifyJWT(tok, testSecret)
	require.NoError(t, err)
	assert.Equal(t, "device-hash-abc123", claims.Subject)
	assert.Equal(t, Issuer, claims.Issuer)
	assert.NotNil(t, claims.IssuedAt)
	assert.NotNil(t, claims.ExpiresAt)
	assert.NotEmpty(t, claims.ID)
}

// TestVerifyJWT_RejectsWrongSecret — a token signed with
// secret A must NOT verify with secret B.
func TestVerifyJWT_RejectsWrongSecret(t *testing.T) {
	tok, err := IssueJWT("user", time.Minute, testSecret)
	require.NoError(t, err)

	_, err = VerifyJWT(tok, []byte("a-different-secret-of-sufficient-length!"))
	require.ErrorIs(t, err, ErrJWTSignatureInvalid,
		"wrong secret must yield ErrJWTSignatureInvalid")
}

// TestVerifyJWT_RejectsEmptySecret — symmetric with IssueJWT.
func TestVerifyJWT_RejectsEmptySecret(t *testing.T) {
	tok, err := IssueJWT("user", time.Minute, testSecret)
	require.NoError(t, err)
	_, err = VerifyJWT(tok, nil)
	require.ErrorIs(t, err, ErrJWTEmptySecret)
	_, err = VerifyJWT(tok, []byte{})
	require.ErrorIs(t, err, ErrJWTEmptySecret)
}

// TestVerifyJWT_RejectsExpired — a token whose exp is in the
// past must fail VerifyJWT. We hand-craft the token so we can
// put it 5 minutes in the past without sleeping the test.
func TestVerifyJWT_RejectsExpired(t *testing.T) {
	now := time.Now().UTC().Add(-5 * time.Minute)
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    Issuer,
			Subject:   "user",
			IssuedAt:  jwt.NewNumericDate(now.Add(-time.Hour)),
			ExpiresAt: jwt.NewNumericDate(now),
			ID:        "expired-jti-pin",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(testSecret)
	require.NoError(t, err)

	_, err = VerifyJWT(tok, testSecret)
	require.ErrorIs(t, err, ErrJWTInvalidClaims,
		"expired token must yield ErrJWTInvalidClaims")
}

// TestVerifyJWT_RejectsForgedIssuer — a token with a different
// iss claim (same secret) must fail. Pins the Issuer constant.
func TestVerifyJWT_RejectsForgedIssuer(t *testing.T) {
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    "evil-issuer",
			Subject:   "user",
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC()),
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(time.Minute)),
			ID:        "forged-iss-pin",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(testSecret)
	require.NoError(t, err)

	_, err = VerifyJWT(tok, testSecret)
	require.ErrorIs(t, err, ErrJWTInvalidClaims,
		"forged iss must yield ErrJWTInvalidClaims")
}

// TestVerifyJWT_RejectsAlgNone — the classic downgrade attack.
// We hand-craft a token with alg=none and a fake signature.
// jwt-go's SigningMethodNone requires the special UnsafeAllowNoneSignatureType
// sentinel to mint a token, so we use it directly. VerifyJWT must
// reject it because WithValidMethods only allows HS256.
func TestVerifyJWT_RejectsAlgNone(t *testing.T) {
	claims := Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer:    Issuer,
			Subject:   "attacker",
			IssuedAt:  jwt.NewNumericDate(time.Now().UTC()),
			ExpiresAt: jwt.NewNumericDate(time.Now().UTC().Add(time.Minute)),
			ID:        "alg-none-attack-pin",
		},
	}
	tok, err := jwt.NewWithClaims(jwt.SigningMethodNone, claims).
		SignedString(jwt.UnsafeAllowNoneSignatureType)
	require.NoError(t, err)

	_, err = VerifyJWT(tok, testSecret)
	require.Error(t, err, "alg=none must be rejected")
	require.NotErrorIs(t, err, ErrJWTEmptySecret,
		"alg=none must NOT be classified as an empty-secret error")
	assert.True(t,
		strings.Contains(err.Error(), "alg=none") ||
			strings.Contains(err.Error(), "signing method") ||
			strings.Contains(err.Error(), "none"),
		"error message should mention the alg=none attack, got: %v", err)
}

// TestVerifyJWT_RejectsMalformedToken — random garbage that
// doesn't even parse as a JWT must fail with ErrJWTInvalidToken.
func TestVerifyJWT_RejectsMalformedToken(t *testing.T) {
	for _, in := range []string{
		"",
		"not-a-jwt",
		"a.b",                // two segments only
		"a.b.c.d",            // four segments
		"!!!.???.@@@",        // bad base64
		strings.Repeat("a", 4) + "." + strings.Repeat("b", 4) + "." + strings.Repeat("c", 4),
	} {
		_, err := VerifyJWT(in, testSecret)
		require.Error(t, err, "input=%q must reject", in)
		if in == "" {
			require.ErrorIs(t, err, ErrJWTInvalidToken)
		}
	}
}

// -----------------------------------------------------------------------------
// Helpers used by the test above.
// -----------------------------------------------------------------------------

// AlgorithmOrEmpty returns the alg header value as a string so a
// test can assert on it without writing its own header parser.
func (c *Claims) AlgorithmOrEmpty(token string) string {
	parser := jwt.NewParser()
	header, _, err := parser.ParseUnverified(token, c)
	if err != nil {
		return ""
	}
	return header.Method.Alg()
}