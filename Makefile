# OpenE2EE — Cross-platform build entry point
# ADR-0008 §2.4 — Sprint 2 PR-MP-4
#
# On Windows: requires Git Bash or WSL (the .sh scripts use bash features).
# On macOS / Linux: works natively.
#
# Usage:
#   make help   # show this message
#   make setup  # verify Go/Flutter/protoc versions + install deps
#   make dev    # docker compose up + flutter run
#   make test   # go test + flutter test
#   make lint   # go vet + flutter analyze
#   make build  # go build (static) + flutter build web
#   make clean  # git clean -fdx  (removes untracked + ignored files)

# --- Tooling locations ---------------------------------------------------
SHELL       := /usr/bin/env bash
SCRIPTS_DIR := scripts

# Detect whether we are running under Git Bash on Windows or a Unix shell.
# Both are POSIX-bash compatible, so a single recipe works.
ifeq ($(OS),Windows_NT)
    BASH     := bash
    RM_HELP  := echo Running on Windows (Git Bash / WSL).
else
    BASH     := bash
    RM_HELP  := echo Running on $(shell uname -s).
endif

# --- Targets -------------------------------------------------------------
.PHONY: help setup dev test lint build clean

help:
	@echo "OpenE2EE — Multiplatform build system"
	@echo ""
	@echo "Targets:"
	@echo "  make setup   — verify Go / Flutter / protoc versions, install deps"
	@echo "  make dev     — start dev stack (docker compose up + flutter run)"
	@echo "  make test    — run all test suites (go test + flutter test)"
	@echo "  make lint    — run linters (go vet + flutter analyze)"
	@echo "  make build   — production build (go static binary + flutter web)"
	@echo "  make clean   — git clean -fdx  (removes untracked + ignored files)"
	@echo ""
	@echo "Platform: $(RM_HELP)"

setup:
	@$(BASH) $(SCRIPTS_DIR)/setup.sh

dev:
	@$(BASH) $(SCRIPTS_DIR)/dev.sh

test:
	@$(BASH) $(SCRIPTS_DIR)/test.sh

lint:
	@$(BASH) $(SCRIPTS_DIR)/lint.sh

build:
	@$(BASH) $(SCRIPTS_DIR)/build.sh

clean:
	@$(BASH) $(SCRIPTS_DIR)/clean.sh
