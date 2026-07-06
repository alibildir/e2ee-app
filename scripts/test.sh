#!/usr/bin/env bash
# scripts/test.sh — Run all test suites (Go + Flutter)
# ADR-0008 §2.4 — Cross-platform entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "==> OpenE2EE test suite"

# ---- Backend: go test ----------------------------------------------------
echo
echo "==> Backend: go test ./..."
if [ -d "backend" ] && [ -f "backend/go.mod" ]; then
    if command -v go >/dev/null 2>&1; then
        (
            cd backend
            go test ./...
        )
    else
        echo "    [SKIP] go not on PATH"
    fi
else
    echo "    [SKIP] backend/go.mod not present (Go service not scaffolded yet)"
fi

# ---- Mobile: flutter test ------------------------------------------------
echo
echo "==> Mobile: flutter test"
if [ -d "mobile" ] && [ -f "mobile/pubspec.yaml" ]; then
    if command -v flutter >/dev/null 2>&1; then
        (
            cd mobile
            flutter test
        )
    else
        echo "    [SKIP] flutter not on PATH"
    fi
else
    echo "    [SKIP] mobile/pubspec.yaml not present"
fi

echo
echo "==> Test run complete."
