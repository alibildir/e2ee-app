// Package telemetry implements the per-session telemetry aggregation
// pipeline for OpenE2EE (Sprint 12.0).
//
// CONTEXT
//
// The mobile app sends per-packet telemetry rows via
// `POST /api/v1/sessions/{id}/telemetry`. The Skorlar screen reads
// the per-session `summary_stats` block from
// `POST /api/v1/sessions/{id}/close` and `GET /api/v1/sessions`.
//
// Between these two endpoints lies the aggregation gap — the raw
// per-packet rows need to be rolled up into a single per-session
// summary that drives the Skorlar card headline `overallScore`
// (see `mobile/lib/services/score_calculator.dart`).
//
// This package owns that rollup. It depends only on a thin
// storage interface (TelemetryAggregatorStore) so it stays
// unit-testable with a fake store.
//
// MVP BEHAVIOUR (Sprint 12.0)
//
// The Aggregator computes the summary in two steps:
//
//	1. ComputeTelemetryAggregate — read the raw `telemetry` rows
//	   for the session and compute COUNT + entropy-based
//	   encryption count. This is the MVP path. It gives us
//	   `total_packets`, `encrypted_packets`, and a derived
//	   `encryption_integrity_pct` (encrypted / total * 100).
//	   Latency / jitter / loss are 0 — we don't have per-packet
//	   latency telemetry yet.
//
//	2. UpsertTelemetryAggregate — persist the computed value to
//	   the `telemetry_aggregates` table so the Skorlar screen
//	   can read it after a process restart (the current
//	   in-memory aggregation was lost on every reload).
//
// Sprint 12.0+ WILL replace step (1) with a `sendSummary` ingest
// path that the mobile `TelemetryService.sendSummary` already
// posts. When that path is wired, the Aggregator will prefer
// the uploaded aggregate over the entropy-based fallback.
//
// FUTURE
//
// - Background worker that computes aggregates for stale
//   sessions (e.g. sessions in `active` state for > 24h with
//   no telemetry rows arriving).
// - TimescaleDB continuous aggregates (when the extension
//   is available on Patroni).
package telemetry

import (
	"context"
	"fmt"

	"github.com/google/uuid"
	"github.com/opene2ee-com/e2ee-app/backend/internal/storage"
)

// TelemetryAggregatorStore is the storage surface this package
// depends on. The full storage.Store satisfies this interface
// implicitly (Go structural typing). Tests can pass a tiny
// fake without dragging in pgx + pgxmock.
type TelemetryAggregatorStore interface {
	ComputeTelemetryAggregate(ctx context.Context, sessionID uuid.UUID) (*storage.TelemetryAggregate, error)
	UpsertTelemetryAggregate(ctx context.Context, agg storage.TelemetryAggregate) error
	GetTelemetryAggregate(ctx context.Context, sessionID uuid.UUID) (*storage.TelemetryAggregate, error)
	ListTelemetryAggregates(ctx context.Context, sessionIDs []uuid.UUID) (map[uuid.UUID]storage.TelemetryAggregate, error)
}

// Aggregator owns the per-session summary_stats pipeline.
//
// Construct via NewAggregator (zero value is NOT usable). The
// service is goroutine-safe as long as the underlying store is
// (PostgresStore is).
type Aggregator struct {
	store TelemetryAggregatorStore
}

// NewAggregator wires the storage layer into a fresh Aggregator.
// Pass the same PostgresStore that powers the rest of the api
// package (wire-up in cmd/server/main.go).
func NewAggregator(store TelemetryAggregatorStore) *Aggregator {
	return &Aggregator{store: store}
}

// AggregateSession computes (or fetches the cached value of) the
// per-session summary for `sessionID` and persists the result.
//
// Behaviour:
//   - If a cached aggregate exists, it is returned untouched
//     (the mobile `sendSummary` ingest path will replace this in
//     Sprint 12.0+).
//   - If no cached aggregate exists, the function reads the raw
//     `telemetry` rows, computes the aggregate in Go, persists
//     it via UpsertTelemetryAggregate, and returns the freshly
//     computed value.
//
// Errors:
//   - storage.ErrNotFound on GetTelemetryAggregate is NOT an
//     error; it triggers the compute path.
//   - Any other error from the store is wrapped and returned
//     as-is so the caller can decide whether to fall back to a
//     placeholder.
//
// If compute fails after GetTelemetryAggregate returned
// ErrNotFound, the function returns an empty aggregate so the
// API layer can degrade gracefully (Skorlar shows a 0/100 card
// instead of a 500).
func (a *Aggregator) AggregateSession(ctx context.Context, sessionID uuid.UUID) (*storage.TelemetryAggregate, error) {
	if sessionID == uuid.Nil {
		return nil, fmt.Errorf("telemetry: AggregateSession: zero session_id")
	}
	cached, err := a.store.GetTelemetryAggregate(ctx, sessionID)
	if err == nil {
		return cached, nil
	}
	if err != storage.ErrNotFound {
		return nil, fmt.Errorf("telemetry: get cached aggregate: %w", err)
	}
	// Cache miss → compute from raw telemetry rows.
	agg, err := a.store.ComputeTelemetryAggregate(ctx, sessionID)
	if err != nil {
		// Graceful degradation: return empty aggregate so the
		// API layer can still respond 200 with the standard
		// placeholder block. The mobile Skorlar screen
		// surfaces a 0/100 card in that case (intentional).
		return &storage.TelemetryAggregate{
			SessionID: sessionID,
		}, fmt.Errorf("telemetry: compute aggregate: %w", err)
	}
	if err := a.store.UpsertTelemetryAggregate(ctx, *agg); err != nil {
		// Persist failure is non-fatal; return the computed
		// value so the API can respond this time. The next
		// request will re-attempt the upsert.
		return agg, fmt.Errorf("telemetry: upsert aggregate: %w", err)
	}
	return agg, nil
}

// ListForSessions returns the cached aggregates for a batch
// of session IDs. Missing aggregates are silently skipped —
// the caller (handleListSessions in api/sessions.go) decides
// whether to compute on demand.
//
// Errors from the underlying store are wrapped and returned.
func (a *Aggregator) ListForSessions(ctx context.Context, sessionIDs []uuid.UUID) (map[uuid.UUID]storage.TelemetryAggregate, error) {
	if len(sessionIDs) == 0 {
		return map[uuid.UUID]storage.TelemetryAggregate{}, nil
	}
	out, err := a.store.ListTelemetryAggregates(ctx, sessionIDs)
	if err != nil {
		return nil, fmt.Errorf("telemetry: list aggregates: %w", err)
	}
	return out, nil
}