// Package storage provides persistent storage adapters for OpenE2EE backend.
//
// It defines two cohesive interfaces:
//
//   - Store      — relational storage (PostgreSQL + TimescaleDB) for devices,
//                  sessions, and time-series telemetry.
//   - ReceiverPool — key/value storage (Redis) for the P2P Active Pool (set
//                    of "nöbet" receivers waiting to be matched).
//
// ADR references:
//   - ADR-0005 §JSON Şemaları (telemetry / session / operator-lookup shapes)
//   - ADR-0006 §Anonim Cihaz Kimliği (device_id_hash, public_key_fp,
//                  masked IP, no payload storage)
package storage

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
)

// ErrNotFound is returned when a row is missing.
var ErrNotFound = errors.New("storage: not found")

// Session represents an E2EE transparency test session.
//
// Fields correspond to `shared/schemas/session.schema.json` (ADR-0005).
type Session struct {
	ID           uuid.UUID  `json:"id"`
	Mode         string     `json:"mode"` // "p2p" | "echobot" | "single"
	TaskType     string     `json:"task_type"`
	SenderHash   *string    `json:"sender_hash,omitempty"`
	ReceiverHash *string    `json:"receiver_hash,omitempty"`
	Status       string     `json:"status"` // "pending" | "active" | "completed" | "incomplete"
	StartedAt    time.Time  `json:"started_at"`
	EndedAt      *time.Time `json:"ended_at,omitempty"`
}

// Telemetry represents an anonymized telemetry sample.
//
// Fields map 1:1 to `shared/schemas/telemetry.schema.json` (ADR-0005 §Örnek).
//
// PRIVACY (ADR-0006): DeviceIDHash is the server-side hash, NEVER the raw
// UUID v7. PublicKeyFP is the SHA-256 fingerprint, NEVER the raw public key
// (the public key itself lives in the `devices` table; private keys never
// leave the device). IPSubnet is masked (/24 IPv4, /48 IPv6). Payload bytes
// are never stored — only the derived score (Entropy) and TLS fingerprint.
type Telemetry struct {
	DeviceIDHash string     `json:"device_id_hash"`
	PublicKeyFP  string     `json:"public_key_fp"`
	Operator     string     `json:"operator"`
	App          string     `json:"app"`
	TLSFP        string     `json:"tls_fp"`
	Entropy      float64    `json:"entropy"`
	SessionID    *uuid.UUID `json:"session_id,omitempty"`
	IPSubnet     string     `json:"ip_subnet,omitempty"`
	Timestamp    time.Time  `json:"timestamp"`
}

// TelemetryAggregate is the per-session aggregate used by the
// `summary_stats` block returned by `POST /api/v1/sessions/{id}/close`
// and embedded in `GET /api/v1/sessions` responses (the mobile
// Skorlar screen reads it via `SessionScoreCalculator.compute`).
//
// Sprint 12.0 — this struct replaces the hard-coded placeholder
// zeros in handleCloseSession. The six numeric fields drive the
// Skorlar card's headline `overallScore` (0-100, higher is better)
// per the weighted formula:
//   overall = 0.4*integrity + 0.3*(1-loss) + 0.2*latency + 0.1*jitter
//
// MVP SOURCES (limitations documented for the Skorlar screen):
//   - total_packets        = COUNT(*) FROM telemetry WHERE session_id
//   - encrypted_packets    = COUNT(*) WHERE session_id AND entropy >= 7.0
//                            (entropy is our proxy for "looks encrypted")
//   - packet_loss_pct      = 0  (no per-packet loss signal yet;
//                               Sprint 12.0+ will derive from sendSummary())
//   - mean_latency_ms      = 0  (per-packet latency not stored;
//                               Sprint 12.0+ will derive from sendSummary())
//   - jitter_ms            = 0  (same; Sprint 12.0+ sendSummary())
//   - encryption_integrity_pct = encrypted_packets / total_packets * 100
//                            (0% when no telemetry rows exist)
//   - captured_at          = UpdatedAt (last write timestamp)
//
// Sprint 12.0+ will introduce the `sendSummary` ingest path (the
// mobile `TelemetryService.sendSummary` endpoint already exists
// in `mobile/lib/services/telemetry_service.dart`). When that
// path is wired, ComputeTelemetryAggregate will prefer the
// aggregate payload over the entropy-based fallback.
type TelemetryAggregate struct {
	SessionID              uuid.UUID
	TotalPackets           int64
	EncryptedPackets       int64
	PacketLossPct          float64
	MeanLatencyMs          float64
	JitterMs               float64
	EncryptionIntegrityPct float64
	CapturedAt             time.Time
	UpdatedAt              time.Time
}

// Store is the persistent (relational) storage interface.
type Store interface {
	// Close releases the underlying connection pool.
	Close()

	// Migrate applies the schema (idempotent). Must be called once at startup.
	// Includes devices, sessions, telemetry, telemetry_aggregates tables +
	// TimescaleDB hypertable (call EnsureTimescale separately, since it
	// requires the extension).
	Migrate(ctx context.Context) error

	// EnsureTimescale creates the TimescaleDB hypertable on `telemetry` and
	// installs the retention policy. Failing gracefully if the extension is
	// not installed — the table itself still works as a regular one.
	EnsureTimescale(ctx context.Context) error

	// Devices.
	UpsertDevice(ctx context.Context, hash string, publicKey []byte, fp string) error

	// Telemetry.
	InsertTelemetry(ctx context.Context, t Telemetry) (int64, error)

	// TelemetryAggregate (Sprint 12.0).
	// UpsertTelemetryAggregate inserts-or-updates the per-session
	// aggregate. Idempotent on (session_id).
	UpsertTelemetryAggregate(ctx context.Context, agg TelemetryAggregate) error
	// GetTelemetryAggregate returns the cached aggregate for a
	// session. Returns (nil, ErrNotFound) when no aggregate exists
	// yet (compute + upsert has not been called for this session).
	GetTelemetryAggregate(ctx context.Context, sessionID uuid.UUID) (*TelemetryAggregate, error)
	// ComputeTelemetryAggregate reads the raw `telemetry` rows
	// for the session and computes the aggregate in Go code
	// (COUNT + entropy proxy). MVP-only path — Sprint 12.0+ will
	// prefer the mobile-uploaded `sendSummary` payload when
	// available.
	ComputeTelemetryAggregate(ctx context.Context, sessionID uuid.UUID) (*TelemetryAggregate, error)

	// Sessions.
	InsertSession(ctx context.Context, s Session) error
	UpdateSessionStatus(ctx context.Context, id uuid.UUID, status string, endedAt *time.Time) error
	GetSession(ctx context.Context, id uuid.UUID) (*Session, error)
	ListSessions(ctx context.Context, limit int) ([]Session, error)
	// ListTelemetryAggregates returns the cached aggregates for a
	// batch of session IDs (used by GET /api/v1/sessions to embed
	// summary_stats without N+1 queries). Missing aggregates are
	// silently skipped — the caller should fall back to the
	// placeholder or compute on demand.
	ListTelemetryAggregates(ctx context.Context, sessionIDs []uuid.UUID) (map[uuid.UUID]TelemetryAggregate, error)

	// KVKK / GDPR: hard-delete all data belonging to a device.
	// Per RISKS.md E3 + BRD §8 FR-7: 7-day SLA for user-initiated delete.
	DeleteUser(ctx context.Context, deviceIDHash string) error
}

// ReceiverPool is the Active Pool (P2P receivers waiting to be matched).
// Implementations must use TTL-based expiry so crashed clients auto-cleanup.
type ReceiverPool interface {
	// Add registers a device hash as an active receiver for the given TTL.
	Add(ctx context.Context, deviceHash string, ttl time.Duration) error

	// PopMatching atomically removes and returns one receiver (any, FIFO-ish).
	// Returns ErrNotFound if the pool is empty.
	PopMatching(ctx context.Context) (string, error)

	// Count returns the current pool size (for /healthz + debugging).
	Count(ctx context.Context) (int64, error)

	// Close releases the underlying client.
	Close() error
}

// DefaultRetentionInterval is the TimescaleDB retention for telemetry.
// Per BRD §E2 (RISKS.md E2): 90 days hot, 1 year cold aggregate — Phase 1
// implements only the hot window.
const DefaultRetentionInterval = "90 days"

// DefaultPoolTTL is how long a receiver stays in the active pool without
// re-registration. Per ADR-0004 §1 "Nöbet 15 dk" → use slightly longer to
// absorb network jitter.
const DefaultPoolTTL = 15 * time.Minute
