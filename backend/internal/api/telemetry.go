package api

// telemetry.go — POST /api/v1/sessions/{id}/telemetry.
//
// This is the hot path of the API: the mobile VPN samples
// packets, computes entropy + TLS fingerprint, and ships the
// aggregate up to the server. We MUST reject any payload
// that doesn't match shared/schemas/telemetry.schema.json — a
// single bad row could pollute the transparency matrix and
// damage the public trust score.
//
// PRIVACY (ADR-0006 §Veri Minimizasyonu):
//   - The schema REQUIRES device_id_hash (the salted hash),
//     NOT the raw UUID v7. Anything else gets a 400.
//   - The schema REQUIRES public_key_fp (the SHA-256
//     fingerprint), NOT the raw public key. Anything else
//     gets a 400.
//   - The schema accepts ip_subnet (the /24 or /48 masked
//     IP), NOT the raw IP. The handler then forwards only
//     ip_subnet to storage.
//   - The schema does NOT include any field shaped like a
//     phone number, IMEI, MAC address, or contact list.
//     Any request that smuggles one in via "additionalProperties"
//     will be rejected because the schema sets
//     additionalProperties:false.
//   - The handler NEVER echoes the parsed body back to the
//     client. The response is just {id: <db_id>, accepted:true}.

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/opene2ee-com/e2ee-app/backend/internal/storage"
)

// telemetryResponse is the minimal success body. The DB row
// id is the only thing the client needs back (so it can
// cross-reference server-side logs during a test run).
type telemetryResponse struct {
	ID        int64  `json:"id"`
	Accepted  bool   `json:"accepted"`
	SessionID string `json:"session_id,omitempty"`
}

// handlePostTelemetry is POST /api/v1/sessions/{id}/telemetry.
func (a *API) handlePostTelemetry() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// (1) Path param: validate the session id before we
		// waste cycles on body parsing.
		idStr := chi.URLParam(r, "id")
		pathSessionID, err := uuid.Parse(idStr)
		if err != nil {
			writeBadRequest(w, "Invalid session id.")
			return
		}
		handleTelemetryInsert(a, w, r, &pathSessionID)
	}
}

// handlePostTelemetryLegacy is POST /api/v1/telemetry.
//
// Sprint 10.1D era — the original Sprint 7 wire-up contract
// carried session_id in the body rather than the URL path.
// That contract never had a matching backend handler, so any
// mobile client (10.1B / 10.1D) that POSTed here received a
// 404. This endpoint restores backward compatibility: the
// body must carry `session_id` (the schema accepts it as
// optional, but the legacy path requires it explicitly).
//
// We delegate to the shared handleTelemetryInsert helper so
// both routes share the schema validation, JSON decode,
// session-id cross-check, and storage insert logic.
func (a *API) handlePostTelemetryLegacy() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		handleTelemetryInsert(a, w, r, nil)
	}
}

// handleTelemetryInsert is the shared body for the two
// telemetry POST handlers. `pathSessionID` is the path-level
// session id when present (the canonical
// /sessions/{id}/telemetry route) or nil when the route is
// the legacy /telemetry POST (in which case the body must
// carry session_id).
//
// Behaviour:
//   - Reads the body, validates against telemetry.schema.json,
//     JSON-decodes into the storage type.
//   - Resolves the session id: prefers the path argument,
//     falls back to the body's `session_id` field, and 400s
//     when neither is set.
//   - Persists via storage.TelemetryWriter (same as the path
//     route).
//   - Returns 202 with the new telemetry row id.
func handleTelemetryInsert(a *API, w http.ResponseWriter, r *http.Request, pathSessionID *uuid.UUID) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeError(w, http.StatusRequestEntityTooLarge, ErrorBody{
				Code:    CodePayloadTooLarge,
				Message: "Request body exceeds size limit.",
			})
			return
		}
		writeBadRequest(w, "Failed to read request body.")
		return
	}
	if len(body) == 0 {
		writeBadRequest(w, "Empty request body.")
		return
	}

	if err := a.deps.Schemas.Validate(SchemaTelemetry, body); err != nil {
		if ve, ok := isValidationError(err); ok {
			writeValidation(w, ve)
			return
		}
		a.deps.Cfg.Logger.Error("telemetry schema validation error",
			"err_kind", "schema",
		)
		writeBadRequest(w, "Schema validation failed.")
		return
	}

	var t decodedTelemetry
	if err := json.Unmarshal(body, &t); err != nil {
		writeBadRequest(w, "Malformed JSON.")
		return
	}

	// Resolve the session id: path first, body fallback,
	// 400 when neither is present (legacy route).
	sessionID := pathSessionID
	if sessionID == nil {
		if t.SessionID == nil {
			writeBadRequest(w, "session_id is required (legacy /telemetry route).")
			return
		}
		sessionID = t.SessionID
	} else if t.SessionID != nil && *t.SessionID != *sessionID {
		// Defence in depth: body session_id, if present, must
		// match the URL path (catches stale mobile retries).
		writeBadRequest(w, "Session id in body does not match URL.")
		return
	}

	storageRow, err := t.toStorage(*sessionID)
	if err != nil {
		writeBadRequest(w, err.Error())
		return
	}
	id, err := a.deps.Cfg.Telemetry.InsertTelemetry(r.Context(), storageRow)
	if err != nil {
		a.deps.Cfg.Logger.Error("insert telemetry failed",
			"err_kind", "db",
			"session_id", sessionID.String(),
		)
		writeInternal(w)
		return
	}

	writeJSON(w, http.StatusAccepted, telemetryResponse{
		ID:        id,
		Accepted:  true,
		SessionID: sessionID.String(),
	})
}

// decodedTelemetry is the request-side shape of one telemetry
// row. It mirrors the relevant subset of telemetry.schema.json
// — the schema validator enforces the contract, this struct is
// just the decoders' convenience.
//
// IMPORTANT: fields the api package never wants to receive are
// OMITTED here. If the schema ever adds a forbidden field, the
// schema validator will still allow it through (the schema is
// the contract for what mobile sends), but the struct decoder
// will silently drop it. That asymmetry is intentional — the
// schema's `additionalProperties:false` is the source of
// truth, not this struct.
type decodedTelemetry struct {
	DeviceIDHash   string    `json:"device_id_hash"`
	PublicKeyFP    string    `json:"public_key_fp"`
	Operator       string    `json:"operator"`
	App            string    `json:"app"`
	TLSFP          string    `json:"tls_fp"`
	Entropy        float64   `json:"entropy"`
	IPSubnet       string    `json:"ip_subnet,omitempty"`
	SessionID      *uuid.UUID `json:"session_id,omitempty"`
	Timestamp      string    `json:"timestamp"` // RFC 3339
	SNI            string    `json:"sni,omitempty"`
	TLSVersion     string    `json:"tls_version,omitempty"`
	OperatorSource string    `json:"operator_source,omitempty"`
	MatchMode      string    `json:"match_mode,omitempty"`
	PeerScore      *float64  `json:"peer_score,omitempty"`
	Confidence     *float64  `json:"confidence,omitempty"`
	Signature      string    `json:"signature,omitempty"`
}

// toStorage converts the wire shape into the storage type.
// We re-parse the timestamp string because storage.Telemetry
// uses time.Time and the handler layer shouldn't rely on the
// caller to send a time.Time JSON form.
func (d decodedTelemetry) toStorage(sessionID uuid.UUID) (storage.Telemetry, error) {
	ts, err := time.Parse(time.RFC3339, d.Timestamp)
	if err != nil {
		return storage.Telemetry{}, errors.New("invalid timestamp format (RFC 3339 required)")
	}
	sid := sessionID
	return storage.Telemetry{
		DeviceIDHash: d.DeviceIDHash,
		PublicKeyFP:  d.PublicKeyFP,
		Operator:     d.Operator,
		App:          d.App,
		TLSFP:        d.TLSFP,
		Entropy:      d.Entropy,
		IPSubnet:     d.IPSubnet,
		SessionID:    &sid,
		Timestamp:    ts.UTC(),
	}, nil
}