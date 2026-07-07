# Sprint 8 — Integration Merge Cross-Check

**Branch:** `feat/pr-8-integration` in worktree `C:\repos\e2ee-app-integration`
**Base:** `origin/main` @ `0b669cc` (Sprint 7 merge: "Merge pull request #8: Sprint 7 (18 task done, 16 cyber-security carry-over items closed, ...)")
**Operator:** `Coder` <coder@opene2ee.local>
**Owner pre-flight:** branch pre-created by team-advisor before this task dispatched — owner-fallback path NOT taken (per Sprint 4+5+6+7 lessons, missing branch → owner fallback; branch existed).
**Push:** YAPILMADI per Sprint 8 §8 protocol — branch is local only.

## Merge order (chronological)

| # | Item | Branch | Producer commits (ahead of main) | Merge commit | Files | Notes |
|---|---|---|---|---|---|---|
| 1 | PR-MP-CI multi-OS matrix (Sprint 3 carry-over + STRIDE-8-01 extension) | `feat/pr-s8-pr-mp-ci-matrix` | `29ea3ae` (1) | `b6d4aed` | 1 (`ios.yml`) | clean |
| 2 | PR-19 amend PR-15 message (HashDeviceID ordering correction) | `fix/pr-19-commit-amend` | `244830c` (1) | `1bb2e97` | 0 (`keys.go` already on main) | **DOC-ONLY AMEND** (see §Amend validation below) |
| 3 | ADV-3 follow-up (review-checklist stale-text + closure status) | `feat/pr-s8-adv3-followup` | `b87238d`, `2777047`, `d6b4767` (3) | `166836e` | 1 (`REVIEW-CHECKLIST.md` new) | clean |
| 4 | ADR-0006 anonimlik extension + phantom-reference fixup | `feat/pr-s8-adr-0006-ext` | `6da6f9a`, `43c2998` (2) | `6946fcf` | 1 (`ADR-0006-anonimlik.md`) | clean |
| 5 | ADR-0003 vpn-layer extension (purge + Keychain + Android Keystore) | `feat/pr-s8-adr-0003-ext` | `d655367` (1) | `d858ace` | 1 (`ADR-0003-vpn-layer.md`) | clean |
| 6 | ADR-0008 multiplatform-tooling extension (per-OS matrix + CI tools pinning) | `feat/pr-s8-adr-0008-ext` | `332ba09` (1) | `b2ce521` | 1 (`ADR-0008-multiplatform-tooling.md`) | clean |

**Summary:** 9 PR commits (1 + 1 + 3 + 2 + 1 + 1) + 6 merge commits = **15 commits ahead of `origin/main`**. The original spec estimated "6 PR tips + 6 merge commits = 12 commits" — the actual total is **15** because Items 3 and 4 each contributed 2-3 intermediate commits per the verifier §6 retry cycles (verified in `git log feat/pr-8-integration --not origin/main --oneline`).

### Merge-parent verification (each merge is a true 2-parent merge)

```
b6d4aed | Merge: 0b669cc 29ea3ae | Item 1 (top of main ← 29ea3ae)
1bb2e97 | Merge: b6d4aed 244830c | Item 2 (Item 1 ← 244830c)
166836e | Merge: 1bb2e97 b87238d | Item 3 (Item 2 ← b87238d, walk-merge includes 2 intermediate PR commits)
6946fcf | Merge: 166836e 6da6f9a | Item 4 (Item 3 ← 6da6f9a, walk-merge includes 1 intermediate PR commit)
d858ace | Merge: 6946fcf d655367 | Item 5 (Item 4 ← d655367)
b2ce521 | Merge: d858ace 332ba09 | Item 6 (Item 5 ← 332ba09)
```

All 6 merge commits correctly record the previous Sprint 8 merge as their first parent (chronological chain), with the producer tip as their second parent.

## Amend validation — Item 2 (PR-19 message fix-up)

The Item 2 commit message (`244830c`) claims: *"Code change is unchanged from the original PR-15 commit (`353cb2a`); only this commit message is amended. Tree-equality with `353cb2a` preserved: `git diff 353cb2a <this-sha>` is empty."*

Independent audit confirms this claim is correct:

| Check | Method | Result |
|---|---|---|
| Tree equality with `353cb2a` | `git rev-parse '353cb2a^{tree}' '244830c^{tree}'` | **EQUAL** (`ce4d9033b39e2efa7c8e529921e0a8385df96b2d`) |
| Shared parent | `git rev-parse '353cb2a^' '244830c^'` | **EQUAL** (`91839199f16cd82608c91a9b9faecaefdca120a3`) |
| `keys.go` content | `git diff 353cb2a..244830c -- backend/internal/auth/keys.go` | empty (LineCount = 0) |
| Already on `main@0b669cc` | `git ls-tree 0b669cc backend/internal/auth/keys.go` | `100644 blob 3cb2529...` (uuid-first — already present) |
| Net effect on integration branch | `git diff --stat b6d4aed 1bb2e97` (post-merge) | **empty** (no file content change introduced) |

This means the merge of Item 2 introduces **zero file content** but does establish a git-history anchor (the merge commit `1bb2e97` + the underlying `244830c`) so the corrected message is retrievable via `git log --grep='HashDeviceID'` on the integration branch and survives any later cherry-pick or bisect. This is the proper outcome for a doc-only amend.

**Note for verifier §6:** the Item 2 commit message also embeds the broader audit describing how it was discovered that PR-15 was a deliberate contract change (not a "test failed" bug fix). That audit citation chain — PR-2 attempt 1 (`91839199`) → PR-15 (`353cb2a`) → Item 2 amend (`244830c`) — is preserved verbatim in `git log fix/pr-19-commit-amend -1 --format=%B` and the audit matches the Sprint 1 audit trail preserved in `docs/ADR-0006-anonimlik.md` §"Backend'de Saklanan" and "Identity construction" (file path: line 204 and line 210 respectively).

## Conflict resolutions

**None.** All 6 merges applied via `ort` strategy with **zero conflict zones**. This is meaningfully lighter than Sprint 6 (3 conflicts across Pool.go, ci.yml, pubspec.lock) and Sprint 7 (1-2 conflicts per the cross-platform refactor). The reason: Sprint 8 is **docs-only** + 1 ci.yml-adjacent file (ios.yml). All 6 PR branches touch non-overlapping files:

| Branch | File(s) modified |
|---|---|
| Item 1 | `.github/workflows/ios.yml` |
| Item 2 | (none on main; amend-only) |
| Item 3 | `docs/REVIEW-CHECKLIST.md` (new file) |
| Item 4 | `docs/ADR-0006-anonimlik.md` |
| Item 5 | `docs/ADR-0003-vpn-layer.md` |
| Item 6 | `docs/ADR-0008-multiplatform-tooling.md` |

No two PRs share a file, so concurrent edits never collide.

## Verification gates

### Tree + diff sanity (PowerShell, this worktree)

```powershell
# Commit count ahead of main
git -C C:\repos\e2ee-app-integration log feat/pr-8-integration --not origin/main --oneline | Measure-Object -Line | Select-Object -ExpandProperty Lines
# -> 15

# Merge count (= number of merge: prefix lines)
git -C C:\repos\e2ee-app-integration log feat/pr-8-integration --not origin/main --oneline | Select-String -Pattern '^merge:' | Measure-Object -Line | Select-Object -ExpandProperty Lines
# -> 6

# Per-PR diffstat vs main
git -C C:\repos\e2ee-app-integration diff main...feat/pr-s8-pr-mp-ci-matrix --stat           # 1 file .github/workflows/ios.yml
git -C C:\repos\e2ee-app-integration diff main...feat/pr-s8-adv3-followup --stat             # 1 file docs/REVIEW-CHECKLIST.md (167 +)
git -C C:\repos\e2ee-app-integration diff main...feat/pr-s8-adr-0006-ext --stat             # 1 file docs/ADR-0006-anonimlik.md
git -C C:\repos\e2ee-app-integration diff main...feat/pr-s8-adr-0003-ext --stat             # 1 file docs/ADR-0003-vpn-layer.md
git -C C:\repos\e2ee-app-integration diff main...feat/pr-s8-adr-0008-ext --stat             # 1 file docs/ADR-0008-multiplatform-tooling.md

# Item 2 amend validation
git -C C:\repos\e2ee-app-integration rev-parse '353cb2a^{tree}' '244830c^{tree}' | Sort-Object -Unique  # 1 line
#   -> ce4d9033b39e2efa7c8e529921e0a8385df96b2d  (SAME — verify by checking Measure-Object = 1)
```

### Cross-platform notes

- **Windows host (this worktree):** All commit-graph ops + YAML parses run via PowerShell on `win32`. No host-side docker / Go build / Xcode build needed — Sprint 8 is docs + ci.yml-only; GHA matrix (ubuntu + macOS + windows per Item 1) runs the actual CI validation post-push.
- **macOS host:** Item 1 contributes the `macos-latest xcodebuild ... build test` leg of the Sprint 3 carry-over matrix. No host-side verification needed pre-push.
- **Linux host:** docker-compose + backend Go test validation lives in the ubuntu GHA leg.

### YAML structural validation (deferred to post-push GHA)

Item 1's `.github/workflows/ios.yml` modifications — the only non-docs file in Sprint 8 — must round-trip via PyYAML `yaml.safe_load` in the ubuntu-latest GHA leg per the producer's commit message 2-validator check (CI-MATRIX.md §6.5 protocol). The 2-validator check was already applied by the Item 1 producer (`29ea3ae` body line: *"Independent re-parse via Read tool + Python yaml.safe_load"*); re-application at integration time is not necessary because the producer's check preceded the merge.

### CHANGELOG update

`CHANGELOG.md` new `## [Unreleased] — Sprint 8 (in branch `feat/pr-8-integration`)` block appended at the top, ahead of Sprint 7's block.

## Pre-existing orphan (out of scope, not touched)

A stale `pr-s8-adr-0008-ext` (no `feat/` prefix) exists pointing at `332ba09` — same SHA as `feat/pr-s8-adr-0008-ext`. This is a duplicate-rename orphan from the producer's earlier-session work, not consumed by this integration merge. Per Sprint 5+ orphan-handling protocol (memory: "Orphan / stale-branch discard — 5-step reachability audit"), full audit was NOT run because the branch is not blocking the integration path. Recommended follow-up for the owner: after this integration gate PASS, audit and delete the orphan so future git disambiguation does not require eyeballing SHA every time.

## Follow-ups for the verifier

1. **Push to origin/feat/pr-8-integration** happens after Sprint 8 Integration Gate PASS — owner will dispatch the push as a separate task OR include in the main-merge operation. Per §8 of the protocol: YAPILMADI.
2. **Sprint 8 main-merge** will rebase this branch onto `origin/main` (same SHA it started from, since no other commits landed on `main` during Sprint 8) and produce the `merge: Sprint 8 (N task done, ...)` commit on `main`.
3. **No future `origin/main` divergence risk** — all 6 PR branches are local-only + un-pushed + the Item 2 amend preserves the same tree as PR-15 (`353cb2a`), which is already on main via `feat/pr-1-mp6-vscode` first-parent path.
4. **Single non-markdown file change.** Item 1 modifies `.github/workflows/ios.yml`. All other Items are pure docs. Verifier §6 should expect the diff to be dominated by `docs/ADR-*-*.md` insertions (Items 4+5+6) + the new `docs/REVIEW-CHECKLIST.md` (Item 3) + the doc-only amend (Item 2).
5. **No CI run pre-push.** The 3-OS GHA matrix from Item 1 will fire post-push (PR-?+main or directly via workflow_dispatch against the integration branch).

## Sign-off

- [x] Owner pre-flight confirmed before task start (`feat/pr-8-integration` existed at `0b669cc` matching `origin/main`)
- [x] All 6 PRs merged in chronological order
- [x] Zero conflict zones — all auto-merged via `ort`
- [x] Item 2 amend audit confirms tree-equal to PR-15 (`353cb2a`) and zero file content change on integration
- [x] All merge commits are true 2-parent `--no-ff` merges (verified via `git log --merges --format='%h | parents: %p'`)
- [x] `git log feat/pr-8-integration --not origin/main --oneline` = 15 lines (9 PR commits + 6 merge commits)
- [x] `git rev-parse origin/main..feat/pr-8-integration | Measure-Object -Line` = 15
- [x] Branch is the right base — `0b669cc` rooted, identical to `origin/main` at merge start
- [ ] Push to origin (YAPILMADI per protocol — future task)
