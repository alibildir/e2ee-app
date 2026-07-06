#!/usr/bin/env bash
# scripts/setup.sh — OpenE2EE development environment setup
# ADR-0008 §2.4 — Cross-platform entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "==> OpenE2EE setup"
echo "    repo root: ${REPO_ROOT}"

# ---- Tool version checks --------------------------------------------------
echo
echo "==> Checking toolchain versions"

# Go (>= 1.26 per ADR-0008 §2.6)
if command -v go >/dev/null 2>&1; then
    GO_VERSION="$(go version | awk '{print $3}')"
    echo "    [OK] go     ${GO_VERSION}"
else
    echo "    [MISSING] go (expected Go 1.26+)"
fi

# Flutter (stable channel)
if command -v flutter >/dev/null 2>&1; then
    FLUTTER_VERSION="$(flutter --version 2>/dev/null | head -n 1 | awk '{print $2}')"
    echo "    [OK] flutter ${FLUTTER_VERSION:-unknown}"
else
    echo "    [MISSING] flutter (stable channel)"
fi

# protoc (Protocol Buffers compiler)
if command -v protoc >/dev/null 2>&1; then
    PROTOC_VERSION="$(protoc --version 2>&1 | awk '{print $2}')"
    echo "    [OK] protoc ${PROTOC_VERSION:-unknown}"
else
    echo "    [MISSING] protoc (Protocol Buffers compiler)"
fi

# Docker (required for dev.sh)
if command -v docker >/dev/null 2>&1; then
    DOCKER_VERSION="$(docker --version 2>&1 | awk '{print $3}' | tr -d ',')"
    echo "    [OK] docker ${DOCKER_VERSION:-unknown}"
else
    echo "    [MISSING] docker (required for 'make dev')"
fi

# ---- Dependency install (placeholder) ------------------------------------
echo
echo "==> Installing backend dependencies (placeholder)"
if [ -d "backend" ] && [ -f "backend/go.mod" ]; then
    if command -v go >/dev/null 2>&1; then
        (
            cd backend
            go mod download
        )
    else
        echo "    (skipped — go not on PATH)"
    fi
else
    echo "    (skipped — backend/go.mod not present)"
fi

echo
echo "==> Installing mobile dependencies (placeholder)"
if [ -d "mobile" ] && [ -f "mobile/pubspec.yaml" ]; then
    if command -v flutter >/dev/null 2>&1; then
        (
            cd mobile
            flutter pub get
        )
    else
        echo "    (skipped — flutter not on PATH)"
    fi
else
    echo "    (skipped — mobile/pubspec.yaml not present)"
fi

echo
echo "==> Setup complete."
echo "    Next: make dev    # start backend (docker compose) + mobile (flutter run)"
