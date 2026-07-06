module github.com/opene2ee-com/e2ee-app/backend

go 1.25.0

// pgx/v5 pin rationale (Sprint 6 PR-38 — hand-off from cyber-security
// report §2.1 SCA-1 / SCA-2 / SCA-3; see
// ~/.mavis/agents/cyber-security/workspace/reports/sprint6-security-review.md).
//
// Pinned version: v5.10.0 (latest stable as of 2026-07-07; confirmed
// by `go list -m -u github.com/jackc/pgx/v5` returning no upgrade and
// `govulncheck@v1.5.0` (DB 2026-06-26) reporting zero findings).
//
// Why this pin matters — three CVEs close at this version:
//
//   CVE-2026-33816  memory-safety bug in pgproto3 (fuzz-found; no known
//                   in-the-wild exploit). Fixed in v5.9.0.
//   CVE-2024-27304  SQL injection via Postgres protocol message-size
//                   integer overflow (attacker splits one query into
//                   multiple messages). Fixed in v5.5.4.
//   CVE-2024-27289  SQL injection via the simple protocol when a
//                   placeholder is immediately preceded by a minus
//                   sign + a second string placeholder. Fixed in v5.5.4.
//
// The first CVE's < 5.9.0 affected range makes v5.9.0 the universal
// floor — v5.10.0 covers all three. Do NOT bump below v5.9.0; the
// hermetic test backend/internal/storage/pgx_pin_test.go
// (TestPgxVersion_PostCVEChain) enforces this floor on every CI run,
// and the `backend-govulncheck` GitHub Actions job in
// .github/workflows/ci.yml re-verifies against the live vulnerability
// DB on every PR.
//
// To bump: edit the require line, run `go mod tidy`, run
// `govulncheck ./...` locally, and verify the new version covers all
// three CVEs (consult https://github.com/jackc/pgx/releases).

require (
	github.com/alicebob/miniredis/v2 v2.38.0
	github.com/go-chi/chi/v5 v5.3.0
	github.com/golang-jwt/jwt/v5 v5.3.1
	github.com/google/uuid v1.6.0
	github.com/gopacket/gopacket v1.7.0
	github.com/gorilla/websocket v1.5.3
	github.com/jackc/pgx/v5 v5.10.0
	github.com/pashagolub/pgxmock/v3 v3.4.0
	github.com/redis/go-redis/v9 v9.21.0
	github.com/stretchr/testify v1.11.1
	github.com/xeipuuv/gojsonschema v1.2.0
)

require (
	github.com/cespare/xxhash/v2 v2.3.0 // indirect
	github.com/davecgh/go-spew v1.1.1 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/rogpeppe/go-internal v1.15.0 // indirect
	github.com/xeipuuv/gojsonpointer v0.0.0-20180127040702-4e3ac2762d5f // indirect
	github.com/xeipuuv/gojsonreference v0.0.0-20180127040603-bd5ef7bd5415 // indirect
	github.com/yuin/gopher-lua v1.1.1 // indirect
	go.uber.org/atomic v1.11.0 // indirect
	golang.org/x/sync v0.17.0 // indirect
	golang.org/x/text v0.29.0 // indirect
	gopkg.in/yaml.v3 v3.0.1 // indirect
)

// gopacket-fork pin (HANDOFF §4 PR-4 + §9 "fork bağımlılığı — ilk
// go mod tidy'de güncel commit hash gerekli").
//
// The opene2ee-com/gopacket fork is API-identical to the upstream
// module at the same commit (the fork's go.mod declares
// `module github.com/gopacket/gopacket`); the `replace` directive
// swaps the upstream module source for the fork's specific commit
// so CI / production get the actual fork code.
//
// To update the fork pin: `git rev-parse HEAD` on the fork's master
// branch on GitHub and replace the commit hash below.
replace github.com/gopacket/gopacket => github.com/opene2ee-com/gopacket v0.0.0-20260624020144-4ff01f2ac30b
