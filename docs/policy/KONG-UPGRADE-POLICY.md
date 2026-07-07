# Kong Gateway Upgrade Cadence Policy

| Field      | Value                                                  |
|------------|--------------------------------------------------------|
| **ID**     | SCA-19                                                 |
| **Owner**  | Architect (mvs_25a7a987f73243899e35a1485c6ba224)      |
| **Source** | Sprint 7 carry-over from cyber-security focused mini-plan (Item 2 / SCA-19) |
| **Status** | Accepted (Sprint 7)                                    |
| **Date**   | 2026-07-07                                             |
| **Applies to** | `infra/docker-compose.yml` `kong` service        |

---

## Context

OpenE2EE uses **Kong Gateway 3.x (DB-less, declarative)** as the public-facing
reverse proxy / API gateway for the Go backend. The image pin lives in
`infra/docker-compose.yml` and the declarative config lives in
`infra/kong/kong.yml` (GitOps — every config change is a PR).

Kong is a security-critical surface: it terminates TLS, enforces JWT auth
(Sprint 5 PR-32), rate-limits, and exposes the admin API. Unlike long-lived
infrastructure components where "if it works, don't touch it" is acceptable,
a public-facing gateway must track upstream security patches on a
**predictable cadence** while still reacting fast to **out-of-band CVEs**.

This policy fixes the cadence, the triggers for unscheduled upgrades, the
rollback procedure, and the smoke-test gate that every Kong image bump must
clear before merge.

> **Cross-link.** This policy assumes the contributor runs on the normalised
> toolchain described in [`docs/ADR-0008-multiplatform-tooling.md`](ADR-0008-multiplatform-tooling.md)
> (`make setup`, `make test`, `docker compose config` on Linux / macOS;
> PowerShell-7 + Git Bash on Windows). Docker compose validation is
> Linux + macOS only per the ADR-0008 runner matrix — Windows contributors
> must rely on `make test` + CI's `docker-compose-config` leg.

---

## Current Pin (as of 2026-07-07)

```yaml
# infra/docker-compose.yml — kong service (line 285)
image: kong:3.8-alpine
```

* **Track:** Kong Gateway 3.x (DB-less mode).
* **Variant:** `alpine` (smaller surface, musl libc; matches our `redis:7-alpine` and `nginx:alpine` normalisation).
* **Source of truth:** the `image:` line in `infra/docker-compose.yml`. There
  is **no** Kong image in any other file — `infra/Dockerfile` does not exist
  for Kong, and CI does not reference Kong images directly.

Whenever this pin moves, this section must be updated as part of the same PR.

---

## Grandfather Clause (current pin past upstream support)

The current pin `kong:3.8-alpine` reached upstream **non-LTS end-of-support
on 2024-12-12** (per Kong's version-support policy: each non-LTS minor is
supported until the next minor; 3.8 was superseded by 3.9 on 2024-09-19 and
formally went out of support 3 months later). As of today (2026-07-07) the
pin has been unsupported for **~19 months**.

This is the situation Trigger #2 (broadened below) exists for. To close the
gap **before** the upstream-paced cadence kicks in:

* A bump PR targeting the **latest available LTS line** (currently
  `kong:3.10-alpine`; verify against [hub.docker.com/r/kong](https://hub.docker.com/r/kong))
  **must land within 14 days of this policy being accepted**.
* The bump PR must clear the full Test Plan (§Test Plan) including the
  `/healthz` prerequisite below.
* Until that bump merges, the production gateway is operating on an
  upstream-unsupported image. This is acknowledged as **accepted risk**
  during the 14-day window and is tracked as a separate line item
  (SCA-19-GRAND) in the Sprint 7 carry-over board.
* Analogous pattern: see the Sprint 7 SCA-22 coturn-TLS work
  (`infra/coturn/turnserver.conf` cipher-list `:!ECDSA` consistency note in
  the verifier minor findings) — both policies apply the same "current pin
  is sub-spec; bump within N days of policy acceptance" rule.

---

## Cadence

Kong Gateway's actual upstream cadence is **~12 weeks per minor version**
(per Kong release-call transcripts and the
[endoflife.date Kong Gateway history](https://endoflife.date/kong-gateway)).
Per Kong's official post-March-2025 support policy, Kong ships **4 minor
versions per year** — one in March, one in June, one in September, one in
December — i.e. **quarterly**. Therefore our cadence is **upstream-paced,
not calendar-paced**: a bump PR fires when upstream releases a new tag, not
on a fixed calendar date.

We adopt a **two-tier upstream-paced cadence**:

| Tier            | Trigger                                         | SLA                        |
|-----------------|-------------------------------------------------|----------------------------|
| **Minor**       | New `kong/kong` GitHub release tag              | PR opened within **5 business days** of upstream tag |
| **Major**       | Review at the start of each calendar quarter    | PR opened within **10 business days** of the cadence date |

### Why upstream-paced (not "monthly")

A "monthly minor" cadence is **unsustainable** because Kong upstream does
not release that often. Pegging the policy to a calendar month would force
a "no upstream tag available → no PR opened" loop every month and erode
trust in the policy. Upstream-paced cadence aligns our PR queue with
upstream reality.

The upstream-release check runs as a CI cron on the first business day of
each month (`.github/workflows/kong-cadence-cron.yml` — to be added when
this policy is operationalised); if no upstream tag exists, no PR is
required. Operators can also trigger the check manually:

```bash
gh release list --repo kong/kong --limit 1 --json tagName,publishedAt
```

### Minor bump

* Triggered by the upstream `kong/kong` GitHub release tag.
* Scope: **patch + minor bump inside the current major track** (e.g. `3.8.1` → `3.9.0`).
* No config changes assumed; a config diff is still required as evidence.
* SLA: PR opened within 5 business days of upstream tag.

### Quarterly major review

* Triggered by the first Monday of January / April / July / October.
* Scope: review the **next major line** (e.g. `3.x` → `4.x` when available).
* Mandatory actions:
  1. Read upstream migration guide end-to-end.
  2. Diff `infra/kong/kong.yml` against the new major's plugin-schema changes
     (`/schemas` endpoint of the new Kong image — see test plan §3).
  3. Bump `image:` and run the full smoke-test gate.
  4. Update this policy's "Current Pin" section.
* SLA: PR opened within 10 business days of the cadence date.

---

## Out-of-band Triggers (skip the cadence)

The following triggers authorise an **unscheduled** Kong upgrade. They are
ranked by urgency.

| # | Trigger                                                                                              | SLA      | Required artefact                            |
|---|-------------------------------------------------------------------------------------------------------|----------|----------------------------------------------|
| 1 | **CVE published** with CVSS ≥ 7.0 affecting our Kong minor line                                       | 48 h     | CVE-ID in commit message + `govulncheck` run |
| 2 | **Upstream support ended** for our pinned minor line — LTS **or** non-LTS                            | 14 days  | Upstream EOL announcement URL in PR body    |
| 3 | **Breaking feature required** by a backend PR (e.g. new auth plugin)                                  | Same sprint as the feature | Plugin-name + docs link in PR body  |
| 4 | **Kong admin API / TLS regression** discovered in prod                                                | 24 h     | Incident report reference in PR body        |

Triggers 1, 2, 4 override the cadence: do not wait for the next upstream
tag or quarterly window. Trigger 3 is normally folded into the feature
sprint — it does not authorise skipping the smoke-test gate.

**Trigger #2 nuance (LTS vs non-LTS).** Kong ships two support tiers:

* **LTS** (currently `3.4`) — supported for **1 year** from date of release.
* **non-LTS** (every other minor, e.g. `3.8`, `3.9`, `3.10`, `3.11`) —
  supported until the **next minor** ships (typically 12 weeks).

Because non-LTS support windows are shorter than LTS ones, **the current
pin (`kong:3.8-alpine`) is the canonical Trigger #2 fire** — it went out
of non-LTS support on 2024-12-12. The Grandfather Clause above is what
closes the gap.

---

## Rollback Procedure

Rollback is the **default response** to any smoke-test failure post-bump.
The compose file + GitOps declarative config together give us a sub-minute
recovery path.

1. **Revert the image pin** in `infra/docker-compose.yml`:
   ```bash
   git revert --no-edit <bump-commit-sha>
   # or, if the bump is the only unmerged PR:
   git checkout origin/main -- infra/docker-compose.yml infra/kong/kong.yml
   ```
2. **Re-pull and re-up**:
   ```bash
   docker compose -f infra/docker-compose.yml --env-file infra/.env pull kong
   docker compose -f infra/docker-compose.yml --env-file infra/.env up -d kong
   ```
3. **Confirm health**:
   ```bash
   docker compose -f infra/docker-compose.yml ps kong
   docker compose -f infra/docker-compose.yml exec kong kong health
   curl -fsS http://localhost:8100/status | jq .
   ```
4. **If the bump also touched `infra/kong/kong.yml`**: the revert must
   restore **both** files in lock-step. A partial revert leaves the gateway
   in a state where `kong reload` (admin API call) would silently drop the
   new plugin config — see §"Common rollback mistakes" below.
5. **Post-mortem** within 48 h of any rollback triggered by Triggers 1 or 4.

### Common rollback mistakes

* **Reverting only the compose file.** Kong declarative config is reloaded
  from `/etc/kong/kong.yml` on every container start (KONG_DECLARATIVE_CONFIG),
  so reverting only `infra/docker-compose.yml` without `infra/kong/kong.yml`
  keeps the new config in place once the old image comes up. **Always revert
  both files together.**
* **`kong reload` after partial rollback.** DB-less Kong ignores admin API
  reload — declarative config is read once at start. A reload call leaves
  you thinking you rolled back when you did not.
* **Skipping the healthcheck.** `kong health` is the only signal that
  confirms the running image matches the declared image. Never trust
  `docker ps` alone.

---

## Test Plan (per upgrade PR)

Every Kong image bump — cadence-driven or trigger-driven — must clear the
following gate before merge. The gate is **static-first** (matches Sprint 5
PR-32 precedent: docker not always available on the contributor's host;
CI is the canonical runner).

### Prerequisites

The following must be merged into `origin/main` **before** any Kong image
bump PR can clear this gate:

* **AUTHZ-2 — `/healthz` under Kong JWT scope**
  (branch `feat/pr-s7-authz2-healthz`, commit `2c09635`,
  merged in Sprint 7 cycle 2 per Item 1 verifier §6 PASS).
  This adds the JWT-protected `healthz` route that Test 4.3 below probes.
  Without AUTHZ-2 merged, Test 4.3 fails with `404` and the entire smoke
  gate is blocked — running the gate on a branch without AUTHZ-2 is a
  wasted CI cycle.
* **SEC-1 — JWT_SECRET dev fallback loud warning** (Sprint 7 Item 8)
  ensures the in-process fail-closed posture complements Kong's
  gateway-level fail-closed posture; otherwise a misconfigured backend
  would let the smoke tests succeed while leaving the prod posture weak.
* **SEC-6/7 — REDIS_PASSWORD required compose fail-closed** (Sprint 7
  Item 10) — Kong forwards DELETE to the backend, which talks to Redis;
  Redis must be authenticated end-to-end before the smoke gate can be
  trusted.

### 1. Compose config validation

```bash
docker compose -f infra/docker-compose.yml config --quiet
```

Expected: exit 0, no output. This catches YAML syntax errors and broken
`${VAR:?required}` expansions without starting any container.

### 2. Compose syntax (Linux / macOS only — per ADR-0008 runner matrix)

```bash
make test-compose
# or equivalently:
docker compose -f infra/docker-compose.yml config
```

`make test-compose` is declared in the root `Makefile` (SCA-19 fix
amendment) and runs the same `docker compose config --quiet` check.
Expected: parsed YAML printed; no anchor / `<<: *default-restart` errors.
**Windows contributors skip this step locally** — the CI
`docker-compose-config` job (Linux + macOS) is the canonical validation.
On Windows without Docker, the Makefile target prints `[SKIP]` and the
contributor relies on CI.

### 3. Schema sanity (Kong declarative config)

```bash
docker run --rm -v "$PWD/infra/kong:/etc/kong:ro" kong:<new-pin>-alpine \
  kong config -c /etc/kong/kong.yml parse
```

Expected: parses without schema-violation warnings. Catches plugin-name
typos and removed fields before we ever boot the gateway.

### 4. Smoke tests (compose up + curl)

```bash
docker compose -f infra/docker-compose.yml --env-file infra/.env up -d kong
docker compose -f infra/docker-compose.yml ps kong        # expect (healthy)
docker compose -f infra/docker-compose.yml exec kong kong health   # expect 200

# 4.1 — admin API reachable
curl -fsS http://localhost:8100/status | jq .

# 4.2 — proxy rejects unauthenticated /api/v1 request (Sprint 5 PR-32)
code=$(curl -s -o /dev/null -w '%{http_code}' \
  http://localhost:8000/api/v1/auth/whoami)
[ "$code" = "401" ] || { echo "FAIL: expected 401, got $code"; exit 1; }

# 4.3 — proxy allows /healthz route (Sprint 7 Item 1, AUTHZ-2 prerequisite)
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8000/healthz)
[ "$code" = "200" ] || { echo "FAIL: expected 200, got $code"; exit 1; }

# 4.4 — JWT round-trip (HS256, matches infra/kong/kong.yml jwt plugin)
#        Uses the Python helper at infra/kong/smoke-jwt.py (SCA-19
#        fix amendment). Requires PyJWT ($ pip install PyJWT) + the
#        $JWT_SECRET env var to match Kong + backend.
python3 infra/kong/smoke-jwt.py
```

Expected: 4.1 → 200; 4.2 → 401; 4.3 → 200; 4.4 → all 3 probes pass
(no-auth → 401, valid JWT → 200, tampered sig → 401). Any deviation =
**FAIL** = trigger the rollback procedure.

### 5. CI gates

The PR must be green on:

* `docker-compose-config` (Linux + macOS matrix leg)
* `privacy-check` (KVKK DELETE smoke test — confirms Kong proxy still
  forwards DELETE correctly)
* `go-build-test` (backend healthcheck exercise via Kong)

If any of these turn red after the Kong bump, the PR is blocked until the
smoke test (step 4) is reproduced locally + a fix or revert lands.

---

## Cross-references

* [`docs/ADR-0008-multiplatform-tooling.md`](ADR-0008-multiplatform-tooling.md)
  — toolchain normalisation; explains why the test plan above is
  Linux / macOS for Docker validation and Windows + Linux + macOS for
  `go test` / `flutter test`. Cited 3 times in this policy: top
  cross-link note (above), Test Plan §2 (runner matrix), this
  references section.
* [`docs/ARCHITECTURE_DECISIONS.md`](ARCHITECTURE_DECISIONS.md) — Kong is
  the §"Kong Konfigürasyonu" decision (DB-less, declarative, GitOps).
* `infra/docker-compose.yml` — `kong` service, line ~285 (`image: kong:3.8-alpine`).
* `infra/kong/kong.yml` — declarative config; **must** be reverted in lock-step
  with the compose file on any rollback (§"Common rollback mistakes").
* `infra/kong/smoke-jwt.py` — JWT round-trip helper referenced in
  Test Plan §4.4 (SCA-19 fix amendment; the file ships in this PR).
* `Makefile` — `make test-compose` target referenced in Test Plan §2
  (SCA-19 fix amendment; the target ships in this PR).
* [`docs/SPRINT-6-PR-39-VERIFICATION.md`](SPRINT-6-PR-39-VERIFICATION.md)
  — the precedent for static-first verification when Docker is unavailable
  on the contributor host.
* `docs/policy/` — directory this policy lives in; SCA-22 coturn-TLS
  policy (Sprint 7 Item 3) ships alongside as the sibling cadence doc.

---

## Change log

| Date       | Bump (old → new)              | Type  | Author / PR          |
|------------|--------------------------------|-------|----------------------|
| 2026-07-07 | (policy authored — no bump)    | docs  | Architect / SCA-19    |
| 2026-07-07 | (policy amended — fix 6 verifier §6 findings: cadence fact, non-LTS trigger, real `smoke-jwt.py`, `Makefile` target, AUTHZ-2 prerequisite, Grandfather Clause) | docs | Architect / SCA-19 amend |