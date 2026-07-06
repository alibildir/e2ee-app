#!/usr/bin/env bash
# scripts/clean.sh — Remove untracked + ignored files from the working tree
# ADR-0008 §2.4 — Cross-platform entry point
#
# `git clean -fdx` removes:
#   - untracked files (-f = force, -d = directories)
#   - files matched by .gitignore (-x)
#
# It will NOT touch:
#   - the .git/ directory            (always protected)
#   - the .gitignore file itself     (tracked, not ignored)
#   - any other tracked file         (only untracked/ignored are removed)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "==> OpenE2EE clean"
echo "    repo root: ${REPO_ROOT}"
echo
echo "    This will run: git clean -fdx"
echo "      - untracked files: REMOVED"
echo "      - .gitignore'd files (e.g. build/, .dart_tool/, dist/): REMOVED"
echo "      - .git/ directory: PRESERVED"
echo "      - .gitignore file: PRESERVED (tracked)"
echo "      - other tracked files: PRESERVED"
echo

# Dry-run first so the user can see what would happen
echo "==> Dry-run (git clean -fdx -n):"
git clean -fdx -n
echo

# Confirm unless --yes / -y is supplied
if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
    printf "Proceed with actual clean? [y/N] "
    read -r reply
    case "${reply}" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

echo
echo "==> Running: git clean -fdx"
git clean -fdx
echo
echo "==> Clean complete."
