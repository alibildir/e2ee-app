#!/usr/bin/env bash
# scripts/build-web.sh - Flutter web build wrapper (PR-27)
# ADR-0008 S2.4 - Cross-platform entry point
#
# Why this script exists
# ----------------------
# `flutter build web` defaults to `lib/main.dart`. OpenE2EE deliberately
# keeps a SEPARATE entry point for the web dashboard at `lib/web/main.dart`
# (see mobile/lib/web/main.dart for the rationale, HANDOFF S4.2 PR-11).
# Until the mobile-only `lib/main.dart` exists (future PR), running
# `flutter build web` without `--target` produces a confusing
# "Target of URI doesn't exist" error against `lib/main.dart`.
#
# This wrapper hard-codes the correct invocation:
#     flutter build web --target=lib/web/main.dart
# (run from inside the `mobile/` Flutter package)
#
# Usage:
#   bash scripts/build-web.sh
#   bash scripts/build-web.sh --release
#   bash scripts/build-web.sh --release --web-renderer canvaskit
#
# Equivalent to: make build-web  (cross-platform Make target)
#
# Mirrors scripts/build-web.ps1 (PowerShell fallback) - keep in sync.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
MOBILE_DIR="${REPO_ROOT}/mobile"
TARGET_DART="${MOBILE_DIR}/lib/web/main.dart"

# --- Friendly pre-flight: ensure flutter project + web entry exist ---------
if [ ! -d "${MOBILE_DIR}" ]; then
    echo ""
    echo "ERROR: Flutter project not found at ${MOBILE_DIR}." >&2
    echo "       Did you clone the full repo?" >&2
    exit 1
fi

if [ ! -f "${TARGET_DART}" ]; then
    echo ""
    echo "ERROR: Flutter web entry not found at expected path: ${TARGET_DART}" >&2
    echo ""
    echo "Why this happens:" >&2
    echo "  OpenE2EE uses a non-standard Flutter web entry point at" >&2
    echo "  mobile/lib/web/main.dart (PR-11 web dashboard). The default" >&2
    echo "  'flutter build web' targets mobile/lib/main.dart (the future" >&2
    echo "  mobile entry point, not yet in this checkout)." >&2
    echo ""
    echo "Fix one of:" >&2
    echo "  - Restore mobile/lib/web/main.dart (the canonical web entry)." >&2
    echo "  - Or update the --target=<path> flag in this wrapper if you" >&2
    echo "    intentionally moved the web entry." >&2
    exit 1
fi

# --- Resolve flutter --------------------------------------------------------
if ! command -v flutter >/dev/null 2>&1; then
    echo "ERROR: flutter not found on PATH." >&2
    echo "       Install Flutter SDK: https://docs.flutter.dev/get-started/install" >&2
    exit 1
fi

# --- Forward extra args to flutter; default to no extras --------------------
# Pass-through flags like --release / --web-renderer <r> are accepted.
# Usage: scripts/build-web.sh --release [--web-renderer canvaskit]
FORWARD_ARGS=("$@")

# --- Header: Sprint 4 PR-27 context ----------------------------------------
echo "==> OpenE2EE Flutter web build (PR-27 wrapper)"
echo "    entry:   mobile/lib/web/main.dart (non-standard; see CONTRIBTING.md)"
echo "    args:    flutter build web --target=lib/web/main.dart ${FORWARD_ARGS[*]:-}"
echo "    output:  mobile/build/web"
echo ""

# --- Run --------------------------------------------------------------------
(
    cd "${MOBILE_DIR}"
    flutter build web --target=lib/web/main.dart "${FORWARD_ARGS[@]}"
)

echo ""
echo "==> Done. Output: mobile/build/web"
