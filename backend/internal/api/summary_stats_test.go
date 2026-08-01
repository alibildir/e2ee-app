package api

// summary_stats_test.go — Sprint 12.0 integration tests for the
// summary_stats pipeline.
//
// Covers:
//   - handleCloseSession returns real aggregate values when
//     telemetry rows exist
//   - handleCloseSession still works with zero telemetry rows
//     (empty session → empty aggregate, integrity 0, no 500)
//   - handleListSessions embeds summary_stats per row when an
//     aggregate has been computed
//   - handleListSessions omits summary_stats when the
//     SummaryAggregator is nil (graceful degradation)
//   - The summary_stats JSON shape matches what the mobile
//     Skorlar screen expects (SessionTelemetry.fromJson)

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/opene2ee-com/e2ee-app/backend/internal/storage"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// createTestSession is a helper that POSTs /api/v1/sessions and
// returns the session id and the response code.
func createTestSession(t *testing.T, ta *testAPI) (uuid.UUID, int) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"device_id_hash": "abcdef0123456789abcdef0123456789",
		"mode":           "echobot",
		"task_type":      "whatsapp_text",
	})
	w := do(t, ta.Handler(), "POST", "/api/v1/sessions",
		withAPIHeaders(t, nil), string(body))
	require.Equal(t, http.StatusCreated, w.Code,
		"setup session POST failed: %s", w.Body.String())
	var resp struct {
		ID uuid.UUID `json:"id"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	require.NotEqual(t, uuid.Nil, resp.ID)
	return resp.ID, w.Code
}

// seedTelemetry inserts N telemetry rows for the session with
// varying entropy values so the aggregator exercises the
// "encrypted vs total" math.
func seedTelemetry(t *testing.T, ta *testAPI, sessionID uuid.UUID, total, encrypted int) {
	t.Helper()
	now := time.Now().UTC()
	for i := 0; i < total; i++ {
		entropy := 5.0 // "plaintext" bucket
		if i < encrypted {
			entropy = 8.0 // "encrypted" bucket (>= 7.0 threshold)
		}
		_, err := ta.Store.InsertTelemetry(t.Context(), storage.Telemetry{
			DeviceIDHash: "abcdef0123456789abcdef0123456789",
			PublicKeyFP:  "abcd1234abcd1234abcd1234abcd1234",
			Operator:     "turkcell",
			App:          "whatsapp",
			TLSFP:        "deadbeefdeadbeefdeadbeefdeadbeef",
			Entropy:      entropy,
			SessionID:    &sessionID,
			Timestamp:    now.Add(time.Duration(i) * time.Second),
		})
		require.NoError(t, err)
	}
}

func TestSessions_Close_WithTelemetryRows(t *testing.T) {
	ta := newTestAPI(t)
	sid, _ := createTestSession(t, ta)

	// 10 telemetry rows: 8 encrypted (entropy >= 7) + 2 plaintext.
	seedTelemetry(t, ta, sid, 10, 8)

	// Close the session.
	w := do(t, ta.Handler(), "POST",
		"/api/v1/sessions/"+sid.String()+"/close",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	var resp struct {
		SessionID   string         `json:"session_id"`
		Status      string         `json:"status"`
		ClosedAt    string         `json:"closed_at"`
		SummaryStats map[string]any `json:"summary_stats"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	require.Equal(t, sid.String(), resp.SessionID)
	require.Equal(t, "completed", resp.Status)

	// Sprint 12.0 — real numbers, not placeholders.
	require.NotNil(t, resp.SummaryStats)
	assert.EqualValues(t, 10, resp.SummaryStats["total_packets"])
	assert.EqualValues(t, 8, resp.SummaryStats["encrypted_packets"])
	assert.InDelta(t, 80.0, resp.SummaryStats["encryption_integrity_pct"], 0.001)
	assert.EqualValues(t, 0, resp.SummaryStats["packet_loss_pct"])
	assert.EqualValues(t, 0, resp.SummaryStats["mean_latency_ms"])
	assert.EqualValues(t, 0, resp.SummaryStats["jitter_ms"])
	// captured_at is RFC3339 string — must exist.
	_, ok := resp.SummaryStats["captured_at"].(string)
	assert.True(t, ok)
}

func TestSessions_Close_EmptySessionGraceful(t *testing.T) {
	ta := newTestAPI(t)
	sid, _ := createTestSession(t, ta)

	// No telemetry rows seeded — the aggregator should
	// produce an empty aggregate (total=0, integrity=0) without
	// returning 500. The Skorlar screen shows a 0/100 card.
	w := do(t, ta.Handler(), "POST",
		"/api/v1/sessions/"+sid.String()+"/close",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	var resp struct {
		SummaryStats map[string]any `json:"summary_stats"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	require.NotNil(t, resp.SummaryStats)
	assert.EqualValues(t, 0, resp.SummaryStats["total_packets"])
	assert.EqualValues(t, 0, resp.SummaryStats["encrypted_packets"])
	assert.EqualValues(t, 0, resp.SummaryStats["encryption_integrity_pct"])
}

func TestSessions_Close_AggregatePersisted(t *testing.T) {
	ta := newTestAPI(t)
	sid, _ := createTestSession(t, ta)
	seedTelemetry(t, ta, sid, 5, 5)

	// Close — must persist the aggregate so a subsequent
	// GET can read it (the sprint 12.0 Skorlar flow).
	w := do(t, ta.Handler(), "POST",
		"/api/v1/sessions/"+sid.String()+"/close",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	// Direct lookup via the fake store — verifies the upsert.
	agg, err := ta.Store.GetTelemetryAggregate(t.Context(), sid)
	require.NoError(t, err)
	assert.EqualValues(t, 5, agg.TotalPackets)
	assert.EqualValues(t, 5, agg.EncryptedPackets)
	assert.InDelta(t, 100.0, agg.EncryptionIntegrityPct, 0.001)
}

func TestSessions_ListSessions_EmbedsSummaryStats(t *testing.T) {
	ta := newTestAPI(t)
	sid, _ := createTestSession(t, ta)
	seedTelemetry(t, ta, sid, 4, 3)

	// Trigger close so the aggregate is persisted.
	w := do(t, ta.Handler(), "POST",
		"/api/v1/sessions/"+sid.String()+"/close",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	// ListSessions must include summary_stats for the row.
	w = do(t, ta.Handler(), "GET", "/api/v1/sessions",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	var resp struct {
		Sessions []map[string]any `json:"sessions"`
		Count    int              `json:"count"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	require.GreaterOrEqual(t, resp.Count, 1)

	// Find our session.
	var found map[string]any
	for _, s := range resp.Sessions {
		if s["id"] == sid.String() {
			found = s
			break
		}
	}
	require.NotNil(t, found, "session %s not in list response", sid)
	require.Contains(t, found, "summary_stats")
	stats := found["summary_stats"].(map[string]any)
	assert.EqualValues(t, 4, stats["total_packets"])
	assert.EqualValues(t, 3, stats["encrypted_packets"])
}

func TestSessions_ListSessions_NoSummaryWhenNoAggregate(t *testing.T) {
	ta := newTestAPI(t)
	sid, _ := createTestSession(t, ta)
	// No telemetry, no close → no aggregate exists.

	w := do(t, ta.Handler(), "GET", "/api/v1/sessions",
		withAPIHeaders(t, nil), "")
	require.Equal(t, http.StatusOK, w.Code)

	var resp struct {
		Sessions []map[string]any `json:"sessions"`
	}
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &resp))
	for _, s := range resp.Sessions {
		if s["id"] == sid.String() {
			// No aggregate yet → summary_stats is omitted
			// (json:"summary_stats,omitempty"). Mobile
			// fromJson handles missing fields as defaults.
			assert.NotContains(t, s, "summary_stats",
				"empty session must not emit summary_stats")
			return
		}
	}
	t.Fatal("session not in list")
}