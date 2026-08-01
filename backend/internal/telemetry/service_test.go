package telemetry

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/opene2ee-com/e2ee-app/backend/internal/storage"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// fakeStore is the minimal store surface the Aggregator depends
// on. The full PostgresStore satisfies the interface via
// structural typing; tests use this fake to avoid dragging
// pgx + pgxmock into the telemetry unit tests.
type fakeStore struct {
	cached map[uuid.UUID]storage.TelemetryAggregate

	getErr        error
	computeErr    error
	upsertErr     error
	listErr       error
	computeResult *storage.TelemetryAggregate
}

func (f *fakeStore) GetTelemetryAggregate(_ context.Context, id uuid.UUID) (*storage.TelemetryAggregate, error) {
	if f.getErr != nil {
		return nil, f.getErr
	}
	agg, ok := f.cached[id]
	if !ok {
		return nil, storage.ErrNotFound
	}
	return &agg, nil
}

func (f *fakeStore) ComputeTelemetryAggregate(_ context.Context, id uuid.UUID) (*storage.TelemetryAggregate, error) {
	if f.computeErr != nil {
		return nil, f.computeErr
	}
	if f.computeResult != nil {
		cp := *f.computeResult
		cp.SessionID = id
		return &cp, nil
	}
	now := time.Now().UTC()
	return &storage.TelemetryAggregate{
		SessionID:              id,
		TotalPackets:           5,
		EncryptedPackets:       4,
		PacketLossPct:          0.0,
		MeanLatencyMs:          0.0,
		JitterMs:               0.0,
		EncryptionIntegrityPct: 80.0,
		CapturedAt:             now,
		UpdatedAt:              now,
	}, nil
}

func (f *fakeStore) UpsertTelemetryAggregate(_ context.Context, agg storage.TelemetryAggregate) error {
	if f.upsertErr != nil {
		return f.upsertErr
	}
	if f.cached == nil {
		f.cached = map[uuid.UUID]storage.TelemetryAggregate{}
	}
	f.cached[agg.SessionID] = agg
	return nil
}

func (f *fakeStore) ListTelemetryAggregates(_ context.Context, ids []uuid.UUID) (map[uuid.UUID]storage.TelemetryAggregate, error) {
	if f.listErr != nil {
		return nil, f.listErr
	}
	out := map[uuid.UUID]storage.TelemetryAggregate{}
	for _, id := range ids {
		if agg, ok := f.cached[id]; ok {
			out[id] = agg
		}
	}
	return out, nil
}

func TestAggregator_AggregateSession_CacheHit(t *testing.T) {
	sid := uuid.New()
	now := time.Now().UTC()
	cached := storage.TelemetryAggregate{
		SessionID:              sid,
		TotalPackets:           42,
		EncryptedPackets:       42,
		EncryptionIntegrityPct: 100.0,
		CapturedAt:             now,
		UpdatedAt:              now,
	}
	store := &fakeStore{cached: map[uuid.UUID]storage.TelemetryAggregate{sid: cached}}
	a := NewAggregator(store)

	got, err := a.AggregateSession(context.Background(), sid)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, int64(42), got.TotalPackets)
	assert.Equal(t, int64(42), got.EncryptedPackets)
}

func TestAggregator_AggregateSession_CacheMissComputesAndUpserts(t *testing.T) {
	sid := uuid.New()
	store := &fakeStore{} // empty cache → ErrNotFound
	a := NewAggregator(store)

	got, err := a.AggregateSession(context.Background(), sid)
	require.NoError(t, err)
	require.NotNil(t, got)
	assert.Equal(t, sid, got.SessionID)
	assert.Equal(t, int64(5), got.TotalPackets)
	// Verify the upsert side-effect.
	_, ok := store.cached[sid]
	assert.True(t, ok, "AggregateSession must upsert the computed value")
}

func TestAggregator_AggregateSession_RejectsZeroUUID(t *testing.T) {
	a := NewAggregator(&fakeStore{})
	_, err := a.AggregateSession(context.Background(), uuid.Nil)
	require.Error(t, err)
}

func TestAggregator_AggregateSession_GetErrorBubblesUp(t *testing.T) {
	sid := uuid.New()
	store := &fakeStore{getErr: errors.New("boom")}
	a := NewAggregator(store)
	_, err := a.AggregateSession(context.Background(), sid)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "boom")
}

func TestAggregator_AggregateSession_ComputeFailureReturnsEmpty(t *testing.T) {
	sid := uuid.New()
	store := &fakeStore{computeErr: errors.New("compute failed")}
	a := NewAggregator(store)
	got, err := a.AggregateSession(context.Background(), sid)
	// Graceful degradation: empty aggregate, error wrapped.
	require.Error(t, err)
	require.NotNil(t, got)
	assert.Equal(t, sid, got.SessionID)
	assert.Equal(t, int64(0), got.TotalPackets)
}

func TestAggregator_AggregateSession_UpsertFailureReturnsValue(t *testing.T) {
	sid := uuid.New()
	store := &fakeStore{upsertErr: errors.New("upsert failed")}
	a := NewAggregator(store)
	got, err := a.AggregateSession(context.Background(), sid)
	// Non-fatal: caller still gets the value.
	require.Error(t, err)
	require.NotNil(t, got)
	assert.Equal(t, sid, got.SessionID)
	assert.Equal(t, int64(5), got.TotalPackets)
}

func TestAggregator_ListForSessions_Empty(t *testing.T) {
	a := NewAggregator(&fakeStore{})
	out, err := a.ListForSessions(context.Background(), nil)
	require.NoError(t, err)
	assert.Empty(t, out)
}

func TestAggregator_ListForSessions_ReturnsCached(t *testing.T) {
	sid1 := uuid.New()
	sid2 := uuid.New()
	now := time.Now().UTC()
	cached := map[uuid.UUID]storage.TelemetryAggregate{
		sid1: {SessionID: sid1, TotalPackets: 10, CapturedAt: now, UpdatedAt: now},
		sid2: {SessionID: sid2, TotalPackets: 20, CapturedAt: now, UpdatedAt: now},
	}
	store := &fakeStore{cached: cached}
	a := NewAggregator(store)

	out, err := a.ListForSessions(context.Background(), []uuid.UUID{sid1, sid2, uuid.New()})
	require.NoError(t, err)
	assert.Len(t, out, 2)
	assert.Equal(t, int64(10), out[sid1].TotalPackets)
	assert.Equal(t, int64(20), out[sid2].TotalPackets)
}

func TestAggregator_ListForSessions_StoreError(t *testing.T) {
	store := &fakeStore{listErr: errors.New("list failed")}
	a := NewAggregator(store)
	_, err := a.ListForSessions(context.Background(), []uuid.UUID{uuid.New()})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "list failed")
}