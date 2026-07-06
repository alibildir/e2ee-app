#!/usr/bin/env bash
# scripts/lint.sh — Run linters (go vet + flutter analyze)
# ADR-0008 §2.4 — Cross-platform entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "==> OpenE2EE lint"

# ---- Backend: go vet -----------------------------------------------------
echo
echo "==> Backend: go vet ./..."
if [ -d "backend" ] && [ -f "backend/go.mod" ]; then
    if command -v go >/dev/null 2>&1; then
        (
            cd backend
            go vet ./...
        )
    else
        echo "    [SKIP] go not on PATH"
    fi
else
    echo "    [SKIP] backend/go.mod not present"
fi

# ---- Mobile: flutter analyze --------------------------------------------
echo
echo "==> Mobile: flutter analyze"
if [ -d "mobile" ] && [ -f "mobile/pubspec.yaml" ]; then
    if command -v flutter >/dev/null 2>&1; then
        (
            cd mobile
            flutter analyze
        )
    else
        echo "    [SKIP] flutter not on PATH"
    fi
else
    echo "    [SKIP] mobile/pubspec.yaml not present"
fi

echo
echo "==> Lint complete."
