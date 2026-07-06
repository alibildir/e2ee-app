package storage

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

// pgxMinVersion is the minimum required github.com/jackc/pgx/v5 version.
//
// The version pin closes three CVEs flagged by the Sprint 6
// cyber-security review (see
// ~/.mavis/agents/cyber-security/workspace/reports/sprint6-security-review.md
// §2.1 SCA-1 / SCA-2 / SCA-3):
//
//   - CVE-2026-33816 — memory-safety in pgproto3 (fixed in v5.9.0)
//   - CVE-2024-27304 — SQL injection via protocol message size overflow
//     (fixed in v5.5.4)
//   - CVE-2024-27289 — SQL injection via simple-protocol placeholder
//     immediately preceded by a minus sign (fixed in v5.5.4)
//
// v5.9.0 is therefore the universal floor; v5.10.0 (current pin) covers
// all three. Bumping pgx/v5 below this floor MUST fail this test so
// the regression is caught by CI before review.
const pgxMinVersion = "5.9.0"

// TestPgxVersion_PostCVEChain is a hermetic runtime guard that asserts
// the pgx/v5 pin in go.mod is at or above pgxMinVersion. It walks up
// the directory tree to find go.mod and parses the `require` line —
// no govulncheck, no network, no filesystem writes. Runs in <1ms.
//
// This is the "defence in depth" companion to the
// `backend-govulncheck` GitHub Actions job (added in the same PR):
//
//   - govulncheck  = canonical vulnerability DB scan (live, per-PR).
//   - this test    = hermetic floor on the pgx/v5 pin (no DB deps,
//                    catches the "accidental downgrade" scenario where
//                    `go mod tidy` brings in a stale direct copy).
//
// If this test fails, EITHER (a) someone bumped pgx/v5 below the
// known-vulnerable floor (forbidden — see go.mod comment) OR (b) the
// go.mod file is no longer where this test expects it.
func TestPgxVersion_PostCVEChain(t *testing.T) {
	const want = "github.com/jackc/pgx/v5"

	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}
	var gomod string
	for i := 0; i < 6; i++ { // backend/ + 5 up
		candidate := filepath.Join(dir, "go.mod")
		if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() {
			gomod = candidate
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	if gomod == "" {
		t.Skipf("go.mod not found near %s (running under go test with custom WORK=%s?)",
			initialWd(), os.Getenv("WORK"))
	}

	raw, err := os.ReadFile(gomod)
	if err != nil {
		t.Fatalf("read %s: %v", gomod, err)
	}
	got, ok := parseGoModRequire(raw, want)
	if !ok {
		t.Fatalf("%s not pinned in %s — drop the pin and add it back", want, gomod)
	}

	// Compare semver numerically — string "<" on "5.10.0" < "5.9.0"
	// is a classic lexicographic-vs-semver trap ('1' < '9' by ASCII).
	stripped := strings.TrimPrefix(got, "v")
	if !versionGE(stripped, pgxMinVersion) {
		t.Fatalf("%s is pinned at %s; required >= v%s (CVE-2026-33816 + CVE-2024-27304 + CVE-2024-27289). "+
			"Run `govulncheck ./...` to verify; bump go.mod pin to a post-patch version "+
			"and re-run `go mod tidy`. See go.mod comment for audit chain.",
			want, got, pgxMinVersion)
	}
}

// parseGoModRequire extracts the pinned version for `path` from a
// go.mod file body. Tolerant of comments, blank lines, indirect tags,
// and the (rare) multi-line `require ( ... )` block. Returns
// (version, true) on match; ("", false) if `path` is not pinned.
//
// Implementation note: Go's module system has `golang.org/x/mod/modfile`
// for this — it's an indirect dep of the build, but importing an
// indirect from a test would require adding it to go.mod. Hand-rolling
// is <30 lines and avoids that surface change.
func parseGoModRequire(body []byte, path string) (string, bool) {
	scanner := strings.Split(string(body), "\n")
	inBlock := false
	for _, raw := range scanner {
		// Strip inline comments first.
		line := raw
		if idx := strings.Index(line, "//"); idx >= 0 {
			line = line[:idx]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Track require ( ... ) blocks.
		if strings.HasPrefix(line, "require") {
			if strings.Contains(line, "(") {
				inBlock = true
				// Continue — the same line may have entries (rare).
			} else {
				inBlock = false
			}
		}
		if !inBlock && !strings.HasPrefix(line, "require") {
			continue
		}
		// Drop trailing ')' that closes a block.
		line = strings.TrimSuffix(strings.TrimSpace(line), ")")
		// Strip leading "require" if we're inside the block (already
		// entered via the line above, but if a single-line require
		// appears without "(", we want to match it too).
		if !inBlock {
			line = strings.TrimPrefix(line, "require")
			line = strings.TrimSpace(line)
		}
		// Now we should have "<path> <version> [// indirect]".
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if fields[0] == path {
			v := fields[1]
			// Sanity: must look like a version (vN.N.N or N.N.N).
			if !strings.HasPrefix(v, "v") {
				v = "v" + v
			}
			return v, true
		}
	}
	return "", false
}

// versionGE reports whether `got` is >= `want` using numeric semver
// comparison on the first three dot-separated components (major, minor,
// patch). Pre-release / build suffixes are ignored — pgx/v5 has never
// shipped a release with -rc / -beta at the same time as a CVE patch.
//
// Examples:
//
//	versionGE("5.10.0", "5.9.0")  // true   ('1' < '9' lex but we use numeric)
//	versionGE("5.9.0",  "5.9.0")  // true   (equal)
//	versionGE("5.5.4",  "5.9.0")  // false  (CVE-2024-27289/27304 affected)
//	versionGE("5.8.99", "5.9.0")  // false  (CVE-2026-33816 affected)
func versionGE(got, want string) bool {
	gotParts := strings.Split(got, ".")
	wantParts := strings.Split(want, ".")
	for i := 0; i < 3; i++ {
		var g, w int
		if i < len(gotParts) {
			n, err := strconv.Atoi(gotParts[i])
			if err != nil {
				return false
			}
			g = n
		}
		if i < len(wantParts) {
			n, err := strconv.Atoi(wantParts[i])
			if err != nil {
				return false
			}
			w = n
		}
		if g != w {
			return g > w
		}
	}
	return true
}

// TestVersionGE_KnownVectors pins the comparison helper itself so a
// future refactor (e.g. someone "optimising" to plain string compare)
// doesn't silently flip 5.10.0 vs 5.9.0. Belt-and-braces.
func TestVersionGE_KnownVectors(t *testing.T) {
	cases := []struct {
		got, want string
		ok        bool
	}{
		{"5.10.0", "5.9.0", true},
		{"5.9.0", "5.9.0", true},
		{"5.9.1", "5.9.0", true},
		{"5.5.4", "5.9.0", false},
		{"5.8.99", "5.9.0", false},
		{"5.0.0", "5.9.0", false},
		{"6.0.0", "5.9.0", true},
		{"5.9", "5.9.0", true}, // patch omitted → treated as 0, equal
	}
	for _, c := range cases {
		if got := versionGE(c.got, c.want); got != c.ok {
			t.Errorf("versionGE(%q, %q) = %v; want %v", c.got, c.want, got, c.ok)
		}
	}
}

// TestParseGoModRequire_KnownShape pins the go.mod parser against a
// minimal fixture so the regex/line-walking above doesn't drift.
// Without this, a future "simplification" that breaks parsing would
// only surface when someone bumps pgx/v5 below the floor — too late.
func TestParseGoModRequire_KnownShape(t *testing.T) {
	body := []byte(`module example.com/foo

go 1.25.0

require (
	github.com/jackc/pgx/v5 v5.10.0
	github.com/redis/go-redis/v9 v9.21.0 // indirect
)

require github.com/google/uuid v1.6.0
`)
	v, ok := parseGoModRequire(body, "github.com/jackc/pgx/v5")
	if !ok || v != "v5.10.0" {
		t.Fatalf("pgx/v5 parse: got (%q,%v); want (v5.10.0,true)", v, ok)
	}
	v, ok = parseGoModRequire(body, "github.com/redis/go-redis/v9")
	if !ok || v != "v9.21.0" {
		t.Fatalf("redis parse: got (%q,%v); want (v9.21.0,true)", v, ok)
	}
	v, ok = parseGoModRequire(body, "github.com/google/uuid")
	if !ok || v != "v1.6.0" {
		t.Fatalf("uuid parse: got (%q,%v); want (v1.6.0,true)", v, ok)
	}
	if _, ok := parseGoModRequire(body, "github.com/does-not-exist"); ok {
		t.Fatal("missing dep reported as present")
	}
}

// initialWd returns the runtime working directory at test start.
// Used in skip messages only.
func initialWd() string {
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return runtime.GOROOT()
}