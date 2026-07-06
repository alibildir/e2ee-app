#!/usr/bin/env bash
# scripts/dev.sh — Start dev environment (docker compose + flutter run)
# ADR-0008 §2.4 — Cross-platform entry point
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "==> OpenE2EE dev environment"

# ---- Backend via docker compose -----------------------------------------
echo
echo "==> Starting backend stack (docker compose up)"
if command -v docker >/dev/null 2>&1; then
    if [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "compose.yml" ] || [ -f "compose.yaml" ]; then
        docker compose up -d
        echo "    docker compose stack started (detached)"
    else
        echo "    [SKIP] no docker-compose.yml/compose.yaml found at repo root"
    fi
else
    echo "    [SKIP] docker not on PATH — install Docker to use the dev stack"
fi

# ---- Mobile via flutter run ----------------------------------------------
echo
echo "==> Launching mobile (flutter run)"
if [ -d "mobile" ] && [ -f "mobile/pubspec.yaml" ]; then
    if command -v flutter >/dev/null 2>&1; then
        (
            cd mobile
            # `-d` is intentionally omitted: flutter will pick a default device.
            # Use `flutter devices` to list available targets.
            flutter run
        )
    else
        echo "    [SKIP] flutter not on PATH"
    fi
else
    echo "    [SKIP] mobile/pubspec.yaml not present"
fi
