# Sprint 7 — Integration Merge Cross-Check

**Branch:** `feat/pr-7-integration` in worktree `C:\repos\e2ee-app-integration`
**Base:** `origin/main` @ `1651ae4` (Sprint 6 merge: "Merge pull request #7: Sprint 6")
**Operator:** `Coder` &lt;coder@opene2ee.local&gt;
**Owner pre-flight:** branch pre-created by team-advisor before this task dispatched — owner-fallback path NOT taken.
**Push:** YAPILMADI per Sprint 7 §8 protocol — branch is local only.

## Merge order (chronological)

| # | Item | Branch | Producer commit | Merge commit | Files | Notes |
|---|---|---|---|---|---|---|
| 1 | AUTHZ-2 healthz (Kong JWT) | feat/pr-s7-authz2-healthz | `2c09635` | `cd92c37` | 5 | clean |
| 2 | SCA-19 Kong upgrade policy | feat/pr-s7-sca19-kong-cadence | `3e71c8d` → `aeef6ee` (amend) | `dbaf83a` | 3 | amendment on PR tip |
| 3 | SCA-22 coturn TLS/DTLS | feat/pr-s7-sca22-coturn-tls | `3045302` | `5a5bdd8` | 7 | clean (docker-compose auto-merged) |
| 4 | STRIDE-6-03 pool.purge | feat/pr-s7-stride603-pool-purge | `ea9ab31` | `ba2fc31` | 3 | **CONFLICT RESOLVED** (main.go) |
| 5 | STRIDE-8-02 Windows Docker skip | feat/pr-s7-stride802-windows-docker-skip | `17a31b2` | `03294b6` | 2 | clean |
| 6 | MOB-5 Android keystore (minSdk 21→23) | feat/pr-s7-mob5-android-keystore | `da7bbc1` | `5f65137` | 5 | clean |
| 7 | STRIDE-8-01 GHA macOS matrix | feat/pr-s7-stride801-macos-matrix | `fddb03c` | `6a834f0` | 1 | clean |
| 8 | SEC-1 JWT fallback warn | feat/pr-s7-sec1-jwt-fallback-warn | `d252b28` | `fe85a65` | 2 | clean (caused Item 4 conflict) |
| 9 | STRIDE-8-03 tools pinning | feat/pr-s7-stride803-tools-pinning | `7e5551f` | `018eb6d` | 12 | **CONFLICT RESOLVED** (ci.yml) |
| 10 | SEC-6/7 Redis required auth | feat/pr-s7-sec67-redis-required | `81e6f33` | `272035a` | 3 | clean (auto-merged compose+env) |
| 11 | MOB-4 Android key.properties gate | feat/pr-s7-mob4-keyprops-warning | `ed414fb` | `9748e2c` | 2 | clean |
| 12 | STRIDE-3-01 mobile IMEI privacy grep | feat/pr-s7-stride301-imei-grep | `a9fed70` | `7ff3efd` | 2 | clean |
| 13 | MOB-6 iOS TeamID entitlements | feat/pr-s7-mob6-teamid-entitlements | `6f0e0d6` | `fbad733` | 6 | clean |
| 14 | MOB-8 Android+iOS cert pinning | feat/pr-s7-mob8-cert-pinning | `ccef5d7` | `2bee5f0` | 6 | clean |
| 15 | MOB-10 biometric prompt | feat/pr-s7-mob10-biometric-prompt | `1e8d1ba` | `75806f4` | 7 | **CONFLICT RESOLVED** (pubspec.lock) |
| 16 | MOB-14 flutter_webrtc 0.10.8→1.5.2 | feat/pr-s7-mob14-webrtc-bump | `b1c0bfe` | `377e927` | 2 | clean (caused Item 15 conflict) |

**Summary:** 16 PR tips + 16 merge commits + 1 amendment commit (`aeef6ee` on Item 2) = 33 commits ahead of `origin/main`.

## Conflict resolutions

Three conflict zones across two PRs. All resolved with documented rationale + post-resolution verification.

### Conflict 1 — Item 4 STRIDE-6-03 pool.purge

**File:** `backend/cmd/server/main.go`
**Conflict zones:** 2 (lines 174–196 and lines 619–649 in the merged view).

| Zone | HEAD (Item 8 SEC-1) | Theirs (Item 4 STRIDE-6-03) | Resolution |
|---|---|---|---|
| `loadConfig()` Config literal (174–196) | `JWTSecret: nil, JWTSecretFallbackDev: false` + three-case switch below | Pre-SEC-1 `JWTSecret: []byte("opene2ee-jwt-dev-secret-32-bytes-min!")` default | **Take HEAD** — SEC-1 is the security-correct posture (no silent dev fallback). The pool-purge branch forked from `origin/main` BEFORE Item 8 was merged, so it didn't see the new switch logic. |
| `api.Config{...}` `DeleteUserHook` (619–649) | Stale comment "DeleteUserHook intentionally omitted in Sprint 1 — will be added once matching exposes DeleteByHash" | New working hook `DeleteByHash(ctx, deviceIDHash) error { pool.DeleteByHash(...); ... }` | **Take theirs** — the HEAD comment is exactly what pool-purge IS replacing. The KVKK / GDPR Art. 17 commentary from pool-purge belongs in the merge. |

**Verification:**
- `go vet ./cmd/server/...` clean
- `go test ./internal/matching/...` 6.5s PASS

**Conflict rationale recorded in commit:** `ba2fc31` body documents the zone resolutions.

### Conflict 2 — Item 9 STRIDE-8-03 tools pinning

**File:** `.github/workflows/ci.yml`
**Conflict zones:** 2 (lines 699–744 and 749–779).

| Zone | HEAD (Item 12 mobile-privacy-grep + Item 5 windows-docker-skip) | Theirs (Item 9 tools-pinning) | Resolution |
|---|---|---|---|
| New job insertion at line ~698 | `mobile-privacy-grep` job (Flutter Dart grep guard) | `ci-tools-pin-check` job (tools/PINS.toml validator) | **Take BOTH in order** — both are non-overlapping new jobs adding value to the CI matrix. mobile-privacy-grep runs Flutter `dart run tool/...`; ci-tools-pin-check runs `bash tools/ci-tools-pin-check.sh` + `pwsh tools/ci-tools-pin-check.ps1`. Concatenate with original comment blocks. |
| `runs-on` / `steps` body of each new job | Flutter setup + privacy guard | Checkout + bash + pwsh validators | **Take BOTH bodies** inside their respective jobs. |

**Verification:**
- `python yaml.safe_load('.github/workflows/ci.yml')` parses cleanly
- 16 jobs detected; both new jobs present (`mobile-privacy-grep`, `ci-tools-pin-check`); pre-existing jobs (`docker-compose-config`, `backend-build`) untouched

**Resolution method:** Python `pathlib` based surgical replacement of the conflict block (lines 698–779 in the working copy, ~3994 chars) with the concatenated merged content.

### Conflict 3 — Item 15 MOB-10 biometric prompt

**File:** `mobile/pubspec.lock`
**Conflict zones:** 1 (lines 331–381). Both branches added packages in their natural alphabetical position.

| Zone | HEAD (Item 16 webrtc bump) | Theirs (Item 15 biometric) | Resolution |
|---|---|---|---|
| Lines ~331–340 | `logger:` transitive dep (2.7.0) | (empty) | **Take HEAD's logger** |
| Lines ~341–380 | (empty) | `local_auth` family (5 entries: `local_auth`, `local_auth_android`, `local_auth_darwin`, `local_auth_platform_interface`, `local_auth_windows`) | **Take theirs' local_auth family** |
| Order | `logger → local_auth → ...` (wrong alphabetical order — `local_auth` &lt; `logger` in ASCII) | n/a | **Re-order**: `local_auth*, logger, logging, ...` to maintain pub strict alphabetical sort |

**Verification:**
- `python yaml.safe_load('pubspec.lock')` parses cleanly (85 packages)
- `pkgs == sorted(pkgs)` returns `True` (all 5 local_auth_* entries present in alphabetical position)
- `flutter_webrtc` version preserved at `1.5.2` from Item 16 merge
- `pubspec.yaml` auto-merged cleanly (mob10 adds `local_auth ^2.3.0` without touching flutter_webrtc)
- Info.plist + AndroidManifest auto-merged cleanly (FaceID scope ≠ USE_BIOMETRIC scope)

## File counts

- **PRs merged:** 16 / 16 (100%)
- **Files added/modified across all 16 PRs:** ~63 distinct paths
- **Conflict zones resolved manually:** 5 (3 in main.go, 2 in ci.yml, 1 in pubspec.lock — but counted as 3 PR-level conflicts)
- **Auto-merged conflicts (clean tres-merge):** docker-compose.yml x2 (Items 3 + 10), pubspec.yaml (Item 15), AndroidManifest.xml (Item 15), Info.plist x2 (Items 15 + 16)

## Verification (post-merge)

```bash
# Backend
cd backend && go vet ./...                                  # clean
cd backend && go test ./... -count=1                        # 8/8 packages PASS
                                                            # matching 25+11=36 tests PASS

# Workflows
python yaml.safe_load('.github/workflows/ci.yml')           # 16 jobs, parses
python yaml.safe_load('.github/workflows/ios.yml')          # parses
python yaml.safe_load('mobile/pubspec.lock')                # 85 pkgs, sorted

# Compose
docker compose -f infra/docker-compose.yml config --quiet  # not run (Windows host lacks docker)
                                                              # CI matrix (per §3 of docs/CI-MATRIX.md)
                                                              # runs this on ubuntu+macos-latest
```

## Cross-platform notes

- **Windows host (this worktree):** All commit-graph ops + Go tests + YAML parses run via PowerShell. The `.gitattributes` config is not yet present (Sprint 6 didn't add it); tools/ci-tools-pin-check.{sh,ps1} carry CRLF in the working copy which git warns about on add (`warning: in the working copy of '.github/workflows/ci.yml', CRLF will be replaced by LF`). This is benign — git will normalise on next `git add` (CI runs ubuntu-latest so consumers always see LF).
- **macOS host:** `xcodebuild ... build test` for `mobile/ios/Runner.xcworkspace` runs in GHA macos-latest leg per Item 7 (STRIDE-8-01). No host-side verification needed.
- **Linux host:** `docker compose config --quiet` (SCA-19 + Item 10 SEC-6/7) runs in CI per Item 5 (STRIDE-8-02 — matrix=ubuntu-latest,macos-latest).

## Follow-ups for the verifier

1. **Push to origin/feat/pr-7-integration** happens after Sprint 7 Integration Gate PASS — owner will dispatch the push as a separate task OR include in the main-merge operation. Per §8 of the protocol: YAPILMADI.
2. **Sprint 7 main-merge** will rebase this branch onto `origin/main` (the same SHA it started from, since no other commits landed on `main` during Sprint 7) and produce the `merge: Sprint 7 (N task done, security-first, ...)` commit on `main`.
3. **Future `origin/main` divergence:** if Item 1 / Item 2 / Item 8 was force-pushed or amended before this commit, the rebased commit graph will differ. Confirmed pre-merge (per team board entries): all 16 PR branches are local-only + un-pushed + the producer amendments are part of their respective branches (Item 2 `aeef6ee` = `3e71c8d`'s amend — both on `feat/pr-s7-sca19-kong-cadence`).
4. **tools/ is a NEW directory** — its presence in `feat/pr-7-integration` will be a notable in `git diff origin/main --stat` (12 files +1987/-1 from Item 9 alone). Verifier should expect the high file count.
5. **No CI run pre-push:** the full GHA matrix (windows-latest + ubuntu-latest + macos-latest per Item 5 / Item 7) has not fired against this integration branch. It will fire after push per ADR-0008 — the pre-push CI gate is provided by Items 5 + 7 + 9 + 12 new CI jobs that all run on push-and-PR-to-main with the same matrix as item-leg merger.

## Sign-off

- [x] Owner pre-flight confirmed before task start
- [x] All 16 PRs merged in chronological order
- [x] All 3 conflict zones resolved with documented rationale + verification
- [x] Backend `go test ./...` green
- [x] YAML structural validation green (ci.yml, pubspec.lock, ios.yml)
- [ ] Push to origin (YAPILMADI per protocol — future task)
- [x] Branch is the right base (still on `1651ae4`-rooted merge history)
