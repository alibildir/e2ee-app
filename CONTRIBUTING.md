# Contributing to OpenE2EE

Thanks for contributing to OpenE2EE. This document collects the conventions
and one-off build commands you will run into when working on the repo. If
something here is missing or wrong, please open an issue.

---

## Building Flutter web

OpenE2EE's Flutter project (`mobile/`) uses **two separate entry points**:

| Target | Entry file              | Purpose                                           |
| ------ | ----------------------- | ------------------------------------------------- |
| Web    | `mobile/lib/web/main.dart`  | Operator/country matrix dashboard (PR-11)     |
| Mobile | `mobile/lib/main.dart`     | _(not yet in this checkout — future Sprint)_   |

This is **non-standard**. Flutter's default `flutter build web` targets
`lib/main.dart`, which does not exist in this checkout (only the web
dashboard does). Running the default command produces a confusing error:

```
Target of URI doesn't exist: 'lib/main.dart'.
```

### The correct command

Always run:

```bash
cd mobile
flutter build web --target=lib/web/main.dart
```

### Cross-platform wrappers (recommended)

To avoid typing the long flag every time, use the wrappers added in
Sprint 4 (PR-27):

```bash
# macOS / Linux / Git Bash on Windows
bash scripts/build-web.sh                          # debug build
bash scripts/build-web.sh --release                # release
bash scripts/build-web.sh --release --web-renderer canvaskit
```

```powershell
# PowerShell (any Windows shell with pwsh)
pwsh -File scripts/build-web.ps1
pwsh -File scripts/build-web.ps1 -Release
pwsh -File scripts/build-web.ps1 -Release -Renderer canvaskit
```

Or via Make (delegates to `scripts/build-web.sh`):

```bash
make build-web                              # debug
make build-web -- --release                 # release (note the `--`)
```

The wrappers also provide a **friendly error** with this same explanation
if the web entry file is missing, so new contributors do not have to
dig through Flutter's output to figure out what went wrong.

### Hot-reload during development

```bash
cd mobile
flutter run -d chrome --target=lib/web/main.dart
```

### Why a separate web entry point?

The web dashboard is part of the same Flutter package as the mobile app
because it shares widgets (`fl_chart`, theme tokens, models) and
tooling (`pubspec.yaml`, `analysis_options.yaml`, integration tests).
Keeping the two entry points rooted in different files lets us evolve
each surface independently (operator analytics vs. mobile e2ee dialogs)
while sharing the Dart code that does not care which target compiled it.

See `mobile/lib/web/main.dart` for the entry point's own rationale and
`docs/HANDOFF.md` §4.2 PR-11 for the broader design context.

### Troubleshooting

| Symptom                                                          | Cause / fix                                                            |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Target of URI doesn't exist: 'lib/main.dart'`                   | You forgot `--target=lib/web/main.dart`. Use the wrappers above.       |
| Web build silently ignores my dashboard changes                  | You accidentally ran `flutter build web` (no `--target`). It compiled the empty stub instead. |
| `flutter not found` from the wrapper                             | Flutter SDK not on PATH. Install from https://docs.flutter.dev/get-started/install. |
| Wrap me! — `flutter build web --release` was rejected            | Old shell. On Windows, call `pwsh -File scripts/build-web.ps1 -Release`. |

---

## Repository layout (quick reference)

```
e2ee-app/
├── backend/         Go service (cmd/server)
├── mobile/          Flutter app (lib/, lib/web/, android/, ios/, web/)
├── infra/           docker-compose, kong, nginx
├── scripts/         Cross-platform build/dev/test/lint helpers (.sh + .ps1)
├── docs/            ADRs, HANDOFF, BRD
├── Makefile         Cross-platform entry point (make help)
└── CONTRIBUTING.md  This file
```

## Common workflows

```bash
make setup     # one-time toolchain check + dependency install
make dev       # docker compose up + flutter run
make lint      # go vet + flutter analyze
make test      # go test + flutter test
make build     # production build (Go + Flutter web)
make build-web # Flutter web only (PR-27 wrapper — uses --target=lib/web/main.dart)
```

## Commit & branch conventions

- Conventional Commits: `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`, `build:`, `ci:`.
- One PR = one logical change. Reference the PR number or HANDOFF § in the body.
- Branch names: `type/pr-N-short-slug` (e.g. `feat/pr-21b-webrtc-flutter`).

## License

By contributing, you agree that your contributions will be licensed under the
same license as the project (see `LICENSE` once added).
