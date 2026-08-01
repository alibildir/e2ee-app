package api

// delete_session_telemetry_legacy_test.go — Sprint 12.0+ tests
// for the two endpoints that the mobile front-end already
// referenced but the backend did not implement:
//
//   - DELETE /api/v1/sessions/{id} — used by
//     session_orchestrator.tearDown() (best-effort).
//   - POST  /api/v1/telemetry      — the Sprint 10.1D contract;
//     body must carry session_id (legacy behaviour).

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/google/uuid"
	"github.com/opene2ee-com/e2ee-app/backend/internal/storage"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// seedSession creates a session and persists it through the
// fakeStore so the handler has something to delete.
func seedSession(t *testing.T, ta *testAPI) uuid.UUID {
	t.Helper()
	sid := uuid.New()
	ta.Store.Sessions[sid] = storage.Session{
		ID:       sid,
		Mode:     "p2p",
		TaskType: "whatsapp_text",
		Status:   "active",
	}
	// Also seed a fake aggregate to verify DeleteSession
	// wipes it as part of the same transaction.
	ta.Store.TelemetryAggregates[sid] = storage.TelemetryAggregate{
		SessionID:              sid,
		TotalPackets:           3,
		EncryptedPackets:       2,
		EncryptionIntegrityPct: 66.6,
	}
	return sid
}

func TestSessions_DeleteSession_HappyPath(t *testing.T) {
	ta := newTestAPI(t)
	sid := seedSession(t, ta)

	w := do(t, ta.Handler(), "DELETE",
		"/api/v1/sessions/"+sid.String(),
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code,
		"body=%s", w.Body.String())

	var resp struct {
		Deleted   bool   `json:"deleted"`
		SessionID string `json:"session_id"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	assert.True(t, resp.Deleted)
	assert.Equal(t, sid.String(), resp.SessionID)

	// Storage side-effects.
	_, sessionExists := ta.Store.Sessions[sid]
	assert.False(t, sessionExists, "session row must be deleted")
	_, aggExists := ta.Store.TelemetryAggregates[sid]
	assert.False(t, aggExists, "aggregate must be wiped with the session")
}

func TestSessions_DeleteSession_Idempotent(t *testing.T) {
	ta := newTestAPI(t)
	sid := seedSession(t, ta)

	// First DELETE removes the row.
	w := do(t, ta.Handler(), "DELETE",
		"/api/v1/sessions/"+sid.String(),
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	// Second DELETE: idempotent — 200 + idempotent:true.
	w = do(t, ta.Handler(), "DELETE",
		"/api/v1/sessions/"+sid.String(),
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)
	var resp struct {
		Deleted   bool `json:"deleted"`
		Idempotent bool `json:"idempotent"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	assert.True(t, resp.Deleted)
	assert.True(t, resp.Idempotent)
}

func TestSessions_DeleteSession_BadUUID(t *testing.T) {
	ta := newTestAPI(t)
	w := do(t, ta.Handler(), "DELETE",
		"/api/v1/sessions/not-a-uuid",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusBadRequest, w.Code)
}

func TestSessions_DeleteSession_ProtectedByJWT(t *testing.T) {
	ta := newTestAPI(t)
	sid := seedSession(t, ta)

	// Strip Authorization so the JWT gate fires, but keep
	// X-API-Version (the APIVersion middleware 400s before
	// IsAuthorized would see the missing header).
	headers := withAPIHeaders(t, nil)
	delete(headers, "Authorization")
	w := do(t, ta.Handler(), "DELETE",
		"/api/v1/sessions/"+sid.String(),
		headers, "")
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

// =====================================================================
// POST /api/v1/telemetry (legacy Sprint 10.1D contract)
// =====================================================================

func TestTelemetry_LegacyRoute_WithSessionID(t *testing.T) {
	ta := newTestAPI(t)
	ta.Store.Sessions[uuid.Nil] = storage.Session{} // placeholder

	sid := uuid.New()
	body, _ := json.Marshal(map[string]any{
		"device_id_hash": "abcdef0123456789abcdef0123456789",
		"public_key_fp":  "abcd1234abcd1234abcd1234abcd1234",
		"operator":       "turkcell",
		"app":            "whatsapp",
		"tls_fp":         "deadbeefdeadbeefdeadbeefdeadbeef",
		"entropy":        7.5,
		"timestamp":      "2026-08-01T00:00:00Z",
		"session_id":     sid.String(),
	})
	w := do(t, ta.Handler(), "POST", "/api/v1/telemetry",
		withAPIHeaders(t, nil), string(body))
	require.Equal(t, http.StatusAccepted, w.Code,
		"body=%s", w.Body.String())

	// Side-effect: telemetry row was inserted with the
	// body-supplied session_id.
	require.Len(t, ta.Store.TelemetryRows, 1)
	assert.NotNil(t, ta.Store.TelemetryRows[0].SessionID)
	assert.Equal(t, sid, *ta.Store.TelemetryRows[0].SessionID)
}

func TestTelemetry_LegacyRoute_RequiresSessionID(t *testing.T) {
	ta := newTestAPI(t)

	// Body has no session_id AND path has none → 400.
	body, _ := json.Marshal(map[string]any{
		"device_id_hash": "abcdef0123456789abcdef0123456789",
		"public_key_fp":  "abcd1234abcd1234abcd1234abcd1234",
		"operator":       "turkcell",
		"app":            "whatsapp",
		"tls_fp":         "deadbeefdeadbeefdeadbeefdeadbeef",
		"entropy":        7.5,
		"timestamp":      "2026-08-01T00:00:00Z",
	})
	w := do(t, ta.Handler(), "POST", "/api/v1/telemetry",
		withAPIHeaders(t, nil), string(body))
	require.Equal(t, http.StatusBadRequest, w.Code,
		"body=%s", w.Body.String())
}

func TestTelemetry_LegacyRoute_ProtectedByJWT(t *testing.T) {
	ta := newTestAPI(t)
	// Use withAPIHeaders to satisfy the APIVersion
	// middleware (it 400s before reaching IsAuthorized when
	// X-API-Version is missing). Then strip Authorization
	// to prove the JWT gate is what enforces 401.
	headers := withAPIHeaders(t, nil)
	delete(headers, "Authorization")
	w := do(t, ta.Handler(), "POST", "/api/v1/telemetry",
		headers, `{"device_id_hash":"a"}`)
	require.Equal(t, http.StatusUnauthorized, w.Code)
}

func TestTelemetry_LegacyRoute_MismatchedSessionID(t *testing.T) {
	ta := newTestAPI(t)

	body, _ := json.Marshal(map[string]any{
		"device_id_hash": "abcdef0123456789abcdef0123456789",
		"public_key_fp":  "abcd1234abcd1234abcd1234abcd1234",
		"operator":       "turkcell",
		"app":            "whatsapp",
		"tls_fp":         "deadbeefdeadbeefdeadbeefdeadbeef",
		"entropy":        7.5,
		"timestamp":      "2026-08-01T00:00:00Z",
		"session_id":     uuid.New().String(),
	})
	// The body has session_id, but we also send a different
	// one via URL — but URL doesn't carry session_id for the
	// legacy route. So we simulate the cross-check by using
	// a route variant where path != body. The canonical
	// legacy route always uses the body's session_id, so
	// this test is N/A for the legacy route — we cover it
	// under the canonical /sessions/{id}/telemetry test
	// in telemetry_test.go. Skip if no path binding.
	_ = body
	w := do(t, ta.Handler(), "POST", "/api/v1/telemetry",
		withAPIHeaders(t, nil), string(body))
	// Body's session_id is used, no conflict to detect.
	require.Equal(t, http.StatusAccepted, w.Code)
}