# CI `-race` Flag — Linux Race Detection Job

| Field        | Value                                           |
|--------------|-------------------------------------------------|
| Status       | Accepted (Sprint 5 PR-31)                       |
| Date         | 2026-07-06                                      |
| Owner        | Coder (Sprint 5 PR-31)                          |
| Sprint       | 5                                               |
| PR           | PR-31 — WebRTC race flag Linux CI               |
| Branch       | feat/pr-31-webrtc-race-flag                     |

This document captures the `go test -race` Linux CI gate added in
**Sprint 5 PR-31**, fulfilling the Sprint 3 PR-21a verifier non-blocking
follow-up note ("TestManager_ConcurrentIceIsRaceFree -race flag Linux
CI'da"). It is **not** a substitute for the CI workflow YAML — see
[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) for the
authoritative job definitions.

## Background — Sprint 3 PR-21a verifier note

Sprint 3 PR-21a shipped the WebRTC signalling backend (Go) with a
**`TestManager_ConcurrentIceIsRaceFree`** test in
`backend/internal/matching/webrtc_test.go`. That test:

1. Creates a fresh `WebRTCSession`.
2. Spins up 50 goroutines that concurrently `AppendICE` on the same
   session.
3. Asserts all 50 calls succeed and no failures are observed.

In MP terms this is an in-house stress test for the `Manager.AppendICE`
mutex / sliding-window ICE-cap critical section. **Without `-race`,
the test passes trivially.** Go's data-race detector (`-race`) is the
only thing that surfaces:

- missing `defer mu.Unlock()` paths,
- map reads concurrent with map writes,
- "happens-after" violations between `RemoteCandidates` and the
  session's `Candidates` map.

The Sprint 3 verifier noted this as a "non-blocking follow-up":

> **Sprint 3 cycle-2 decision** (2026-07-06, `sprint3-cycle2-decision.json`):
> "2 ops follow-up non-blocking: TestManager_ConcurrentIceIsRaceFree
> -race flag Linux CI'da, FAILED_OFFER state machine extension."

This document describes the former; PR-31's accompanying code commit
also addresses the latter.

## What PR-31 added

PR-31 introduces a **dedicated `go-test-race` job** in
`.github/workflows/ci.yml`. The job:

- **Runs on `ubuntu-latest`** only (`-race` adds ~2x wall-clock cost;
  keeping it off Windows / macOS matrix legs keeps those fast).
- **Provides the same services as `go-build-test`**: a TimescaleDB
  service on `localhost:5432` and a Redis 7 on `localhost:6379`, so
  the integration packages (`auth`, `storage`) hit the same backend
  config they do in the matrix.
- **Sets `GOMAXPROCS=4`** so the thread-sanitiser has enough
  scheduler headroom on the GitHub-hosted Ubuntu runners to surface
  races that only show up under multi-core interleaving.
- **Runs `go test -race -count=1 ./...`** — no cover, no upload,
  no `gofmt` check, no `go vet` (those are covered by `backend-lint`,
  `backend-test`, and `go-build-test` respectively).

Why dedicated? `backend-test` already had `go test -race -cover` in
the YAML (added in Sprint 3 PR-MP-CI), but that bundled `-race` with
cover-upload, gofmt, vet, etc. — when that job fails it's harder to
tell whether the cause is a race, a coverage threshold miss, or a
formatting regression. PR-31 gives `-race` its own page in the Actions
UI so the failure mode is unambiguous.

## Why not put `-race` on the matrix

The matrix `go-build-test` (`ubuntu-latest` + `macos-latest` +
`windows-latest`) is intentionally **hermetic-friendly without
`-race`** so a green matrix leg is a fast signal that the source
compiles and tests pass on all three runners. Adding `-race` to each
matrix leg would roughly double the wall-clock on each leg, costing CI
minutes without exposing anything the matrix doesn't already see —
the matrix verifies "the same Go source passes on Linux, macOS, and
Windows"; the race job is "on Linux, no race conditions exist".

This split was the explicit Sprint 3 PR-MP-CI design choice (see
`backend-test` and the matrix's inline comments).

## How to run locally

```sh
# Standard — no race
cd backend
go test -count=1 ./...

# With race detection
go test -race -count=1 ./...

# Run just the WebRTC state-machine + concurrent tests
go test -race -count=1 -run 'TestManager_ConcurrentIceIsRaceFree|TestTransition|TestManager_FailOffer|TestManager_ApplyOffer_BadSDP' -v ./internal/matching/
```

`go test -race` requires `cgo` on Linux unless you use the pre-built
race detector; the GitHub Actions `ubuntu-latest` runners ship with
`gcc` available so `-race` works out of the box. On **Windows**
locally `-race` requires `cgo` (and a C compiler); the Mavis memory
note `Go on Windows: skip -race (cgo off by default)` documents this
gotcha — for local-Windows verification prefer
`go test -count=1 ./...` (still catching most logic bugs) and rely on
the CI `-race` job for the canonical race-coverage signal.

## Interaction with PR-31's other change

PR-31 ships two things in one commit:

1. **`go-test-race` job** (this document).
2. **`FAILED_OFFER` state machine extension** in
   `backend/internal/matching/webrtc.go`
   (see PR-31 deliverable / `git grep FAILED_OFFER backend/`).

The race job is exercised against the new state-machine tests:

- `TestManager_ConcurrentIceIsRaceFree` (Sprint 3 baseline, kept
  intact; this is the explicit `_testname_` the Sprint 3 verifier
  noted).
- `TestTransition_NewToFailedOffer` (PR-31 new).
- `TestTransition_FailedOfferIsTerminal` (PR-31 new).
- `TestManager_FailOffer_FromNewState` (PR-31 new).
- `TestManager_FailOffer_NotApplicableFromConnecting` (PR-31 new).
- `TestManager_ApplyOffer_BadSDP_MarksFailedOffer` (PR-31 new,
  integration through `Manager.ApplyOffer`'s new failure path).
- `TestManager_ApplyOffer_OffererMismatch_MarksFailedOffer`
  (PR-31 new).
- `TestManager_FailSession_StoresReason_OnFreshSession` (PR-31 new).
- `TestSnapshot_FailedReason` (PR-31 new).

These run under `-race` because they:

- Touch the manager's session map (concurrent reads vs writes).
- Set/check the per-session mutex ordering.
- Bounce through the `m.mu` (map) lock after touching `ws.mu`.

If any of those tests regress under `-race`, the `go-test-race`
job page in GitHub Actions will surface the race stack trace
unambiguously (it does NOT share a page with cover, vet, or build
failures).

## Cross-references

- Sprint 3 PR-21a decision: `sprint3-cycle2-decision.json` line 5.
- Sprint 5 PR-31 plan: `sprint5-master-plan.yaml` lines 169–213
  (task `pr-31-webrtc-race-flag`).
- PR-31 branch: `feat/pr-31-webrtc-race-flag` from `origin/main`
  @ `fbb0b49` (Sprint 4 merged).
- Sprint 3 PR-MP-CI: `.github/workflows/ci.yml` lines 14–27 (the
  top-of-file rationale block).
- ADR-0008 (multiplatform tooling): `docs/ADR-0008-multiplatform-tooling.md`
  (the OS matrix decision that PR-31 inherits).
