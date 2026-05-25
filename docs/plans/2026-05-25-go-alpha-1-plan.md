# ca-bootstrap v2.0.0-alpha.1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ca-bootstrap v2.0.0-alpha.1` — a Go static binary that implements `version` and `doctor` subcommands (read-only), distributed as 5-platform GitHub Releases.

**Architecture:** Single Go module at repo root. `cmd/ca-bootstrap/main.go` is the entry, dispatches to `internal/cli/*.go` via cobra. `doctor` reads an embedded `manifest/tools.yaml` (`//go:embed`), probes the PATH per tool via the `internal/detect` interface, prints a human report, exits with `0`/`1`/`2`. PowerShell tree archived under `legacy/`.

**Tech Stack:** Go 1.23+, `spf13/cobra`, `gopkg.in/yaml.v3`, stdlib `embed` + `testing`. GitHub Actions for CI + release matrix.

**Process discipline (Peter, 2026-05-25):** Outside-in TDD. Write all 7 acceptance tests in one batch (RED phase). Then implement smallest unit to GREEN one test at a time. Refactor between greens. Tutorial doc (`docs/tutorials/tdd-walkthrough.md`) updated **inside the same commit** as each task per the [keep-spec-and-workflow-html-in-sync feedback rule](../../.claude/projects/-Users-petergiannopoulos-Documents-Projects-ChannelAssistDev-ca-tools-ca-bootstrap/memory/feedback_keep_spec_and_workflow_html_in_sync.md).

**Spec reference:** [`docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`](../specs/2026-05-25-go-v2-0-alpha-1-spec.md) — every § citation below points there.

---

## File structure

Files this plan creates or modifies, grouped by responsibility:

| Path | Responsibility | Created in task |
|---|---|---|
| `legacy/` (entire tree) | Frozen PS implementation, archived | Task 1 |
| `legacy/README.md` | "Why this directory exists" pointer | Task 1 |
| `go.mod`, `go.sum` | Go module declaration + deps | Task 2 |
| `cmd/ca-bootstrap/main.go` | Entry point. Build-time ldflag vars. Cobra root.Execute(). | Task 2 |
| `internal/cli/root.go` | Cobra root command + global flag wiring | Task 2 |
| `internal/cli/version.go` | `version` subcommand | Task 5 |
| `internal/cli/doctor.go` | `doctor` subcommand + output formatting | Task 10 |
| `internal/manifest/manifest.go` | YAML load + schema validation + embedded manifest | Task 6 |
| `internal/detect/detect.go` | `Detector` interface + `Tool`/`Result` types | Task 7 |
| `internal/detect/detect_unix.go` | macOS + Linux probe (`//go:build darwin || linux`) | Task 8 |
| `internal/detect/detect_windows.go` | Windows probe + winget fallback (`//go:build windows`) | Task 9 |
| `internal/detect/version_parse.go` | Semver compare + regex parse | Task 7 |
| `tests/acceptance/acceptance_test.go` | The 7 mandatory tests (`//go:build acceptance`) | Task 4 |
| `tests/acceptance/testdata/*.yaml` | Fixture manifests for acceptance tests | Task 3 |
| `internal/manifest/testdata/*.yaml` | Fixture manifests for unit tests | Task 6 |
| `.github/workflows/ci.yml` | vet + lint + unit/integration test on 3 OS | Task 12 |
| `.github/workflows/release.yml` | 5-platform build matrix + GH Release publish | Task 13 |
| `.gitignore` | Add Go-era ignores (`/dist/`, `*.test`, etc.) | Task 2 |
| `VERSION` | Updated to `2.0.0-alpha.1` | Task 14 |
| `README.md` (root) | Go-era install instructions, SmartScreen unblock notes | Task 14 |
| `CHANGELOG.md` | `v2.0.0-alpha.1` entry under [Unreleased] | Task 14 |
| `docs/tutorials/tdd-walkthrough.md` | The tutorial — grows incrementally with each task | All tasks |

---

## Branch and PR strategy

| PR # | Branch | Contains | Depends on |
|---|---|---|---|
| #87 (open) | `docs/go-rewrite-pivot` | Pivot doc + README banner + CHANGELOG entry | — |
| Next | `docs/go-alpha-1-spec` | alpha.1 spec doc + collaboration HTML | #87 |
| Next | `docs/go-alpha-1-plan` | This plan doc | #87 |
| TaskRange | `chore/migration-and-scaffold` | Tasks 1–4 (migration + Go scaffold + 7 failing tests + tutorial-ch-1-thru-4) | Spec PR |
| TaskRange | `feat/alpha-1-impl` | Tasks 5–11 (implementations + refactors + tutorial-ch-5-thru-11) | Migration PR |
| TaskRange | `chore/alpha-1-ci-release` | Tasks 12–13 (CI + release workflows + tutorial-ch-12-thru-13) | Impl PR |
| TaskRange | `release/v2.0.0-alpha.1` | Tasks 14–15 (README/CHANGELOG/VERSION + tag) | All above merged |

Three implementation PRs after the doc PRs. Atomically reviewable.

---

## Task 1 — Repository migration (PS → `legacy/`)

**Files:**
- Move: every PS file/dir at repo root → `legacy/<path>` via `git mv`
- Create: `legacy/README.md`
- Modify: `.gitignore` (no Go-specific changes yet — Task 2)
- Update: `docs/tutorials/tdd-walkthrough.md` (create the file; add chapter 1)

**Branch:** `chore/migration-and-scaffold` (off `dev`, AFTER #87 + spec PR + plan PR merged)

- [ ] **Step 1: Verify clean working tree on the right branch**

```bash
git checkout dev && git pull --ff-only origin dev
git checkout -b chore/migration-and-scaffold
git status                             # expect "working tree clean"
```

Expected: `On branch chore/migration-and-scaffold`, `nothing to commit, working tree clean`.

- [ ] **Step 2: Verify PS files to be moved**

```bash
ls -la *.ps1 *.sh Makefile make.ps1 2>/dev/null
ls -d lib/ commands/ steps/ scripts/ templates/ tests/ 2>/dev/null
```

Expected: lists the PS-era files. If any are missing, stop and investigate before proceeding.

- [ ] **Step 3: Create `legacy/` directory placeholder**

```bash
mkdir -p legacy
```

- [ ] **Step 4: `git mv` PS files to `legacy/`**

```bash
git mv bootstrap.ps1 legacy/
git mv bootstrap.sh legacy/
git mv ca-bootstrap.ps1 legacy/
git mv make.ps1 legacy/
git mv Makefile legacy/
git mv lib legacy/lib
git mv commands legacy/commands
git mv steps legacy/steps
git mv scripts legacy/scripts
git mv templates legacy/templates
git mv tests legacy/tests
git status --short
```

Expected: `git status --short` shows `R  <old> -> legacy/<old>` for every moved entry. No untracked PS files remain at root.

- [ ] **Step 5: Write `legacy/README.md`**

Create `legacy/README.md` with this exact content:

```markdown
# legacy/ — frozen PowerShell implementation of ca-bootstrap

This directory contains the **v1.9.0** PowerShell implementation of ca-bootstrap, frozen in place as of 2026-05-25.

**Why is it here?** See the pivot decision record: [`docs/specs/2026-05-25-go-rewrite-pivot.md`](../docs/specs/2026-05-25-go-rewrite-pivot.md).

**What's the archival tag?** `legacy/v1.9.0` at commit `008b2e2`. Use `git checkout legacy/v1.9.0` to inspect the last functional PowerShell state.

**Will it still run?** Yes, subject to the known limitations the rewrite is escaping (see § 2 of the pivot doc). No new features will land here. Critical user-blocker bugs *may* be fixed minimally during the lame-duck period.

**Where's the active development?** The Go rewrite lives at the repo root. See the top-level [`README.md`](../README.md).
```

- [ ] **Step 6: Create the tutorial doc with chapter 1**

Create `docs/tutorials/tdd-walkthrough.md` (use the skeleton in **Appendix A** at the bottom of this plan; populate Chapter 1 "The migration" with the actual git commands run above + a narrative paragraph explaining why we do this BEFORE the Go scaffold).

- [ ] **Step 7: Verify**

```bash
ls -la                                  # expect: legacy/, docs/, manifest/, .github/, CLAUDE.md, CHANGELOG.md, DESIGN.md, LICENSE, README.md, VERSION, .gitignore, etc. NO loose .ps1/.sh files.
ls legacy/                              # expect: bootstrap.ps1, bootstrap.sh, ca-bootstrap.ps1, Makefile, make.ps1, README.md, lib/, commands/, steps/, scripts/, templates/, tests/
git log --follow legacy/bootstrap.ps1 -- | head -5   # rename history preserved
```

- [ ] **Step 8: Commit**

```bash
git add legacy/README.md docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
chore(migration): archive PowerShell tree under legacy/

Atomic git-mv of every PS-era file at the repo root to legacy/.
Per docs/specs/2026-05-25-go-rewrite-pivot.md, the PowerShell
implementation is frozen at tag legacy/v1.9.0 (commit 008b2e2)
and being replaced by a Go CLI distributed as static binaries.

Adds legacy/README.md pointing at the pivot doc + archival tag.
Adds docs/tutorials/tdd-walkthrough.md (chapter 1) — the live
record of this rewrite for onboarding new contributors later.

manifest/, docs/, .github/ and the top-level docs (README,
CHANGELOG, LICENSE, CLAUDE.md, DESIGN.md, VERSION) stay at root.
Subsequent commits will scaffold the Go module alongside them.

git log --follow continues to trace per-file history.

Refs: AB#<NEW-MIGRATION-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Note:** `AB#<NEW-MIGRATION-PBI>` is a placeholder — file the migration PBI via `az boards work-item create` BEFORE this commit (per [pr-metadata-checklist](../../.claude/skills/pr-metadata-checklist/SKILL.md)). Verify with `az boards work-item show --id N` before referencing.

---

## Task 2 — Go module scaffold

**Files:**
- Create: `go.mod`, `go.sum` (via `go mod init` and `go mod tidy`)
- Create: `cmd/ca-bootstrap/main.go`
- Create: `internal/cli/root.go`
- Modify: `.gitignore` (add Go ignores)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 2)

**Branch:** continue on `chore/migration-and-scaffold`

- [ ] **Step 1: Initialize Go module**

```bash
go mod init github.com/ChannelAssist/ca-bootstrap
```

Expected: creates `go.mod` with `module github.com/ChannelAssist/ca-bootstrap` and `go 1.23` (or matching system Go version).

- [ ] **Step 2: Create `cmd/ca-bootstrap/main.go`**

```go
// Package main is the entry point for ca-bootstrap.
package main

import (
	"os"

	"github.com/ChannelAssist/ca-bootstrap/internal/cli"
)

// Build-time injected via -ldflags. Default values are "dev" sentinels
// so local `go build` produces something recognisable in bug reports.
var (
	Version   = "dev"
	Commit    = "unknown"
	BuildTime = "unknown"
)

func main() {
	cli.SetBuildInfo(Version, Commit, BuildTime)
	if err := cli.Execute(); err != nil {
		os.Exit(1)
	}
}
```

- [ ] **Step 3: Create `internal/cli/root.go`** with cobra root + `SetBuildInfo`

```go
// Package cli wires the cobra root command and shared state for ca-bootstrap.
package cli

import (
	"github.com/spf13/cobra"
)

var (
	version   = "dev"
	commit    = "unknown"
	buildTime = "unknown"
)

// SetBuildInfo is called by main with ldflag-injected build metadata.
func SetBuildInfo(v, c, t string) {
	version = v
	commit = c
	buildTime = t
}

var rootCmd = &cobra.Command{
	Use:   "ca-bootstrap",
	Short: "ChannelAssist developer bootstrap",
	Long:  `ca-bootstrap takes a fresh laptop to a working ChannelAssist development environment.`,
}

// Execute runs the cobra dispatcher. Returns non-nil if a subcommand
// signalled an exit-1-class error; subcommands handle their own
// exit-2 (drift) paths via os.Exit directly.
func Execute() error {
	return rootCmd.Execute()
}
```

- [ ] **Step 4: Add cobra dep**

```bash
go get github.com/spf13/cobra@latest
go mod tidy
```

Expected: `go.mod` lists `github.com/spf13/cobra`; `go.sum` populated.

- [ ] **Step 5: Confirm it compiles**

```bash
go build -o /tmp/ca-bootstrap-scaffold-check ./cmd/ca-bootstrap
echo $?
rm -f /tmp/ca-bootstrap-scaffold-check
```

Expected: exit 0, no compile errors. The binary doesn't do anything yet (no subcommands wired), but the module compiles.

- [ ] **Step 6: Update `.gitignore`**

Modify `.gitignore`. Add a Go section at the bottom:

```gitignore

# ─── Go ─────────────────────────────────────────────
/dist/
*.test
*.out
coverage.out
ca-bootstrap                            # local-build binary (never check in)
```

- [ ] **Step 7: Update the tutorial doc with chapter 2**

Append to `docs/tutorials/tdd-walkthrough.md`: chapter 2 "Scaffolding the Go module before writing any test." Cover: why we add cobra now even though no subcommand uses it yet (the empty root cmd compiles; we'll add subcommands as we GREEN tests), why `internal/` matters (Go's enforced encapsulation), how `-ldflags` will be wired later.

- [ ] **Step 8: Commit**

```bash
git add go.mod go.sum cmd/ internal/ .gitignore docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
feat(go): scaffold Go module at repo root

Adds the minimum Go scaffold needed for the first acceptance test to
compile: go.mod, an empty cobra root command, main.go that calls
into internal/cli. Build-metadata vars are present as "dev" sentinels;
release.yml will inject real values via -ldflags.

No subcommands wired yet — they get added one at a time as we GREEN
acceptance tests starting in Task 5.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 2.

Refs: AB#<NEW-MIGRATION-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3 — Test fixture infrastructure

**Files:**
- Create: `tests/acceptance/testdata/two-real-tools.yaml`
- Create: `tests/acceptance/testdata/one-missing-required.yaml`
- Create: `tests/acceptance/testdata/one-impossibly-new.yaml`
- Create: `tests/acceptance/testdata/one-missing-optional.yaml`
- Create: `tests/acceptance/testdata/malformed.yaml`
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 3)

**Branch:** continue on `chore/migration-and-scaffold`

- [ ] **Step 1: Create `tests/acceptance/testdata/two-real-tools.yaml`**

```yaml
# Used by TestDoctor_AllToolsPresent_ExitsZero.
# Both tools must exist on every CI runner: `go` (we just installed it)
# and `git` (required by every checkout step). Versions are set low
# enough that any modern install passes.
version: 1
tools:
  - id: go
    name: Go
    optional: false
    min_version: "1.20.0"
    detect:
      command: go
      version_flag: version
      version_regex: 'go(\d+\.\d+(?:\.\d+)?)'
  - id: git
    name: Git
    optional: false
    min_version: "2.20.0"
    detect:
      command: git
      version_flag: --version
      version_regex: '(\d+\.\d+\.\d+)'
```

- [ ] **Step 2: Create `tests/acceptance/testdata/one-missing-required.yaml`**

```yaml
# Used by TestDoctor_RequiredToolMissing_ExitsTwo.
# `xyzzy-nonexistent` is a name no real tool ships with.
version: 1
tools:
  - id: xyzzy-nonexistent
    name: Xyzzy
    optional: false
    detect:
      command: xyzzy-nonexistent
      version_flag: --version
      version_regex: '(\d+\.\d+\.\d+)'
```

- [ ] **Step 3: Create `tests/acceptance/testdata/one-impossibly-new.yaml`**

```yaml
# Used by TestDoctor_RequiredToolBelowMin_ExitsTwo.
# `go` exists on the runner, but min_version 99.0.0 is impossibly high
# so the present-but-old code path triggers.
version: 1
tools:
  - id: go
    name: Go
    optional: false
    min_version: "99.0.0"
    detect:
      command: go
      version_flag: version
      version_regex: 'go(\d+\.\d+(?:\.\d+)?)'
```

- [ ] **Step 4: Create `tests/acceptance/testdata/one-missing-optional.yaml`**

```yaml
# Used by TestDoctor_OptionalToolMissing_ExitsZeroWithWarning.
# Missing tool with optional: true → exit 0, ⚠ warning line.
version: 1
tools:
  - id: xyzzy-optional
    name: Xyzzy Optional
    optional: true
    detect:
      command: xyzzy-optional
      version_flag: --version
      version_regex: '(\d+\.\d+\.\d+)'
```

- [ ] **Step 5: Create `tests/acceptance/testdata/malformed.yaml`**

```yaml
# Used by TestDoctor_ManifestParseError_ExitsOneToStderr.
# Deliberately invalid YAML: unterminated string.
version: 1
tools:
  - id: "this string never ends
    detect:
      command: anything
```

- [ ] **Step 6: Update tutorial with chapter 3**

Append chapter 3 "Why fixtures come before tests." Cover: the testdata convention in Go (`testdata/` is special-cased by the build system — won't be compiled as Go), why we picked `go` and `git` as our "must exist" tools (every CI runner has them), why `xyzzy-nonexistent` is safer than a real-but-uncommon tool (no false positive if someone has a niche tool installed), and the deliberately-broken YAML pattern.

- [ ] **Step 7: Commit**

```bash
git add tests/acceptance/testdata/ docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
test(fixtures): add acceptance-test fixture manifests

Five YAML fixtures driving the 7 mandatory acceptance tests
(spec §9.2). Two depend on real tools that ship on every CI runner
(go, git); three drive synthetic scenarios (missing required,
below-min, missing optional, malformed YAML).

tutorial: docs/tutorials/tdd-walkthrough.md chapter 3.

Refs: AB#<NEW-MIGRATION-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 — Write all 7 failing acceptance tests (RED)

**Files:**
- Create: `tests/acceptance/acceptance_test.go`
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 4)

**Branch:** continue on `chore/migration-and-scaffold`

- [ ] **Step 1: Create `tests/acceptance/acceptance_test.go`**

```go
//go:build acceptance

// Package acceptance contains the 7 mandatory acceptance tests for
// ca-bootstrap v2.0.0-alpha.1 (spec §9.2). They MUST exist and fail
// before any non-test code in internal/ or cmd/ is committed.
//
// Run: go test -tags acceptance ./tests/acceptance/...
package acceptance

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// buildBinary compiles ca-bootstrap into a temp directory and returns
// the path to the built binary. Each test gets its own build to avoid
// race conditions and ldflag pollution.
func buildBinary(t *testing.T) string {
	t.Helper()
	tmpDir := t.TempDir()
	binName := "ca-bootstrap"
	if runtime.GOOS == "windows" {
		binName += ".exe"
	}
	binPath := filepath.Join(tmpDir, binName)

	// Walk up from this file to repo root so `go build` finds cmd/.
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	repoRoot := filepath.Join(cwd, "..", "..")

	cmd := exec.Command("go", "build",
		"-ldflags",
		"-X main.Version=2.0.0-test -X main.Commit=testcommit -X main.BuildTime=2026-05-25T00:00:00Z",
		"-o", binPath,
		"./cmd/ca-bootstrap")
	cmd.Dir = repoRoot
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("build failed: %v\nstderr: %s", err, stderr.String())
	}
	return binPath
}

// run invokes the binary with the given args and an optional manifest
// override via $CA_BOOTSTRAP_MANIFEST. Returns stdout, stderr, exit code.
func run(t *testing.T, binPath string, manifest string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(binPath, args...)
	if manifest != "" {
		cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST="+manifest)
	} else {
		// Set to a path that definitely doesn't exist — for the
		// "manifest missing" test we want a clean error, not an
		// accidentally-picked-up neighbour file.
		cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST=/dev/null/no-such-manifest")
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exitCode := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exitCode = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	return stdout.String(), stderr.String(), exitCode
}

// fixture returns the absolute path to a testdata fixture by name.
func fixture(t *testing.T, name string) string {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return filepath.Join(cwd, "testdata", name)
}

// ───────────────────────── the 7 tests ─────────────────────────

func TestVersion_PrintsSemverCommitAndBuildTime(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, "", "version")
	if exit != 0 {
		t.Fatalf("version: expected exit 0, got %d", exit)
	}
	pattern := regexp.MustCompile(`^ca-bootstrap (\S+) \(commit (\S+), built (\S+)\)\s*$`)
	if !pattern.MatchString(strings.TrimSpace(stdout)) {
		t.Errorf("version output did not match expected format.\ngot:\n%q", stdout)
	}
	if !strings.Contains(stdout, "2.0.0-test") {
		t.Errorf("version output missing ldflag-injected version.\ngot:\n%q", stdout)
	}
}

func TestDoctor_AllToolsPresent_ExitsZero(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "two-real-tools.yaml"), "doctor")
	if exit != 0 {
		t.Fatalf("doctor: expected exit 0 (no drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "✓ go") || !strings.Contains(stdout, "✓ git") {
		t.Errorf("doctor: expected ✓ lines for go and git. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "2 ok") {
		t.Errorf("doctor: expected '2 ok' summary. got:\n%s", stdout)
	}
}

func TestDoctor_RequiredToolMissing_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "one-missing-required.yaml"), "doctor")
	if exit != 2 {
		t.Fatalf("doctor: expected exit 2 (drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "✗ xyzzy-nonexistent") {
		t.Errorf("doctor: expected ✗ line for xyzzy-nonexistent. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "1 drift") {
		t.Errorf("doctor: expected '1 drift' in summary. got:\n%s", stdout)
	}
}

func TestDoctor_RequiredToolBelowMin_ExitsTwo(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "one-impossibly-new.yaml"), "doctor")
	if exit != 2 {
		t.Fatalf("doctor: expected exit 2 (drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "✗ go") {
		t.Errorf("doctor: expected ✗ line for go (below min). got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "99.0.0") {
		t.Errorf("doctor: expected min_version 99.0.0 echoed in drift message. got:\n%s", stdout)
	}
}

func TestDoctor_OptionalToolMissing_ExitsZeroWithWarning(t *testing.T) {
	bin := buildBinary(t)
	stdout, _, exit := run(t, bin, fixture(t, "one-missing-optional.yaml"), "doctor")
	if exit != 0 {
		t.Fatalf("doctor: expected exit 0 (no required drift), got %d. stdout:\n%s", exit, stdout)
	}
	if !strings.Contains(stdout, "⚠ xyzzy-optional") {
		t.Errorf("doctor: expected ⚠ line for xyzzy-optional. got:\n%s", stdout)
	}
	if !strings.Contains(stdout, "1 missing-optional") {
		t.Errorf("doctor: expected '1 missing-optional' in summary. got:\n%s", stdout)
	}
}

func TestDoctor_ManifestMissing_ExitsOneToStderr(t *testing.T) {
	bin := buildBinary(t)
	// Pass an env var pointing at a file that does not exist.
	cmd := exec.Command(bin, "doctor")
	cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST=/tmp/this-file-does-not-exist-2026.yaml")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exit := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		exit = exitErr.ExitCode()
	}
	if exit != 1 {
		t.Fatalf("doctor: expected exit 1 (system error), got %d", exit)
	}
	if !strings.Contains(stderr.String(), "manifest") {
		t.Errorf("doctor: expected stderr to mention 'manifest'. got:\n%s", stderr.String())
	}
}

func TestDoctor_ManifestParseError_ExitsOneToStderr(t *testing.T) {
	bin := buildBinary(t)
	_, stderr, exit := run(t, bin, fixture(t, "malformed.yaml"), "doctor")
	if exit != 1 {
		t.Fatalf("doctor: expected exit 1 (parse error), got %d", exit)
	}
	lower := strings.ToLower(stderr)
	if !strings.Contains(lower, "parse") && !strings.Contains(lower, "yaml") {
		t.Errorf("doctor: expected stderr to mention 'parse' or 'yaml'. got:\n%s", stderr)
	}
}
```

- [ ] **Step 2: Run the tests and verify RED**

```bash
go test -tags acceptance ./tests/acceptance/... -v 2>&1 | head -50
```

Expected: at LEAST the first test to fail at the build step (`internal/cli` has no `version` subcommand wired). Acceptable failure modes (all count as the "right kind of RED"):
- `build failed: ...` — cli.Execute() returns nil so the binary has no subcommands; `version` is an unknown command. Cobra exits 1.
- `expected exit 0, got 1` — binary exits 1 because `version` isn't a recognised subcommand.
- For doctor tests: same — no `doctor` subcommand registered.

**Unacceptable failure modes (means the test itself is broken, not the absence of code):**
- Compile errors in the test file
- "could not find go binary" or similar test-harness failures

If you see unacceptable failures: stop, fix the test, re-run. Tests must fail because **the feature is missing**, not because the tests can't run.

- [ ] **Step 3: Update tutorial with chapter 4**

Append chapter 4 "RED: writing all 7 tests at once." Cover: the `//go:build acceptance` build tag (why we gate these so default `go test ./...` doesn't try to build the binary every time), the `buildBinary` helper pattern (why each test builds fresh — ldflag isolation), why the env-var-only manifest path keeps tests hermetic, and *the meaning of seeing all 7 tests fail* — this is the discipline-confirming step.

- [ ] **Step 4: Commit**

```bash
git add tests/acceptance/acceptance_test.go docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
test(acceptance): add the 7 mandatory failing tests (RED phase)

Per spec §9.2, these 7 tests must exist and fail before any non-test
code lands in internal/ or cmd/. They define the acceptance contract
for v2.0.0-alpha.1: 1 test for `version`, 6 for `doctor`.

Each test builds a fresh binary into t.TempDir() with deterministic
ldflag values so the version-output assertion is stable. The
$CA_BOOTSTRAP_MANIFEST env var is the only manifest source the tests
use (set to /dev/null/... for the missing-manifest case) — keeps
tests hermetic.

Expected state after this commit: `go test -tags acceptance ./tests/...`
reports 7/7 failing for the right reason (no version or doctor
subcommand wired yet). Implementations land in Tasks 5-10.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 4 — RED phase
                                                            ^^^^

Refs: AB#<NEW-MIGRATION-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

This commit closes the migration PR. Push branch + open PR with all 12 metadata fields per the checklist. Title:

```
chore(migration): archive PowerShell tree under legacy/, scaffold Go module, RED phase tests (AB#<NEW>)
```

---

## Task 5 — Implement `version` (GREEN test 1)

**Files:**
- Create: `internal/cli/version.go`
- Modify: `internal/cli/root.go` (register the subcommand)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 5)

**Branch:** new `feat/alpha-1-impl` off `dev`, AFTER migration PR merged

- [ ] **Step 1: Re-confirm RED — `TestVersion_*` fails**

```bash
go test -tags acceptance -run TestVersion ./tests/acceptance/... -v 2>&1 | tail -10
```

Expected: FAIL.

- [ ] **Step 2: Create `internal/cli/version.go`**

```go
package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print version, commit, and build time, then exit",
	RunE: func(cmd *cobra.Command, args []string) error {
		fmt.Printf("ca-bootstrap %s (commit %s, built %s)\n", version, commit, buildTime)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
```

- [ ] **Step 3: Run the test — verify GREEN**

```bash
go test -tags acceptance -run TestVersion ./tests/acceptance/... -v 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 4: Run ALL acceptance tests — confirm others still RED**

```bash
go test -tags acceptance ./tests/acceptance/... 2>&1 | tail -15
```

Expected: 1 PASS (TestVersion), 6 FAIL (doctor tests). This is the correct intermediate state.

- [ ] **Step 5: Run unit + integration tests (none yet exist)**

```bash
go test ./... 2>&1 | tail -5
```

Expected: `ok` for every package, no tests run yet (no _test.go files outside `tests/acceptance/`). This confirms no regressions.

- [ ] **Step 6: Update tutorial chapter 5**

"GREEN test 1 — the smallest possible subcommand." Cover: cobra's `init()` registration pattern (why we don't `rootCmd.AddCommand` in main.go), `RunE` vs `Run` (returning errors vs swallowing), and the satisfying "first green" moment.

- [ ] **Step 7: Commit**

```bash
git add internal/cli/version.go docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
feat(cli): implement version subcommand (GREEN test 1)

Minimal cobra subcommand that prints the ldflag-injected build
metadata in the format defined by spec §5.

TestVersion_PrintsSemverCommitAndBuildTime now passes; the 6 doctor
tests stay red until Tasks 6-10.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 5.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6 — Manifest loader + unit tests (GREEN tests 6 & 7)

**Files:**
- Create: `internal/manifest/manifest.go`
- Create: `internal/manifest/manifest_test.go`
- Create: `internal/manifest/testdata/{valid-minimal,missing-version,unsupported-version,missing-tools,tool-missing-id,duplicate-tool-id,invalid-min-version,missing-detect-command}.yaml`
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 6)

**Branch:** continue on `feat/alpha-1-impl`

- [ ] **Step 1: Re-confirm RED — `TestDoctor_ManifestMissing_*` and `TestDoctor_ManifestParseError_*` fail**

```bash
go test -tags acceptance -run 'TestDoctor_Manifest' ./tests/acceptance/... -v 2>&1 | tail -10
```

Expected: FAIL (doctor command not yet registered).

- [ ] **Step 2: Create the manifest unit-test fixtures**

Create each file with minimal valid-or-invalid content per spec §7.1. Example for `valid-minimal.yaml`:

```yaml
version: 1
tools:
  - id: git
    detect:
      command: git
```

For each error-case fixture (`missing-version.yaml`, `tool-missing-id.yaml`, etc.), construct the smallest YAML that triggers exactly one validation rule. (See spec §7.1 for the 6 rules.)

- [ ] **Step 3: Create `internal/manifest/manifest_test.go` FIRST (before manifest.go)**

```go
package manifest

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestLoad_ValidMinimal(t *testing.T) {
	m, err := Load(filepath.Join("testdata", "valid-minimal.yaml"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m.Version != 1 {
		t.Errorf("version: want 1, got %d", m.Version)
	}
	if len(m.Tools) != 1 || m.Tools[0].ID != "git" {
		t.Errorf("tools: want [git], got %+v", m.Tools)
	}
}

func TestLoad_Errors(t *testing.T) {
	cases := []struct {
		file string
		want string  // substring expected in error message
	}{
		{"missing-version.yaml",       "version"},
		{"unsupported-version.yaml",   "unsupported manifest version"},
		{"missing-tools.yaml",         "tools"},
		{"tool-missing-id.yaml",       "missing required 'id'"},
		{"duplicate-tool-id.yaml",     "duplicate tool id"},
		{"invalid-min-version.yaml",   "invalid min_version"},
		{"missing-detect-command.yaml","missing required detect.command"},
	}
	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			_, err := Load(filepath.Join("testdata", tc.file))
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.want)
			}
			if !contains(err.Error(), tc.want) {
				t.Errorf("error %q did not contain %q", err.Error(), tc.want)
			}
		})
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("testdata/does-not-exist.yaml")
	if err == nil {
		t.Fatal("expected error for missing file")
	}
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

// contains is a case-insensitive substring helper for error-message assertions.
func contains(haystack, needle string) bool {
	// implemented in Step 4 alongside the package
	return defaultContains(haystack, needle)
}
```

- [ ] **Step 4: Run the manifest tests — verify RED**

```bash
go test ./internal/manifest/...
```

Expected: build error (`Load` undefined). That's the correct kind of RED — feature is missing, not test bug.

- [ ] **Step 5: Create `internal/manifest/manifest.go`** with embedded manifest + Load

```go
// Package manifest loads and validates the tools manifest YAML.
//
// The default manifest is embedded at build time (`//go:embed`).
// $CA_BOOTSTRAP_MANIFEST overrides with a filesystem path; useful for
// tests and custom-manifest scenarios (spec §6.5).
package manifest

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// ErrNotFound is returned when the manifest file referenced by
// $CA_BOOTSTRAP_MANIFEST does not exist.
var ErrNotFound = errors.New("manifest not found")

//go:embed all:../../manifest/tools.yaml
var embeddedManifest []byte

// Manifest is the top-level structure of tools.yaml.
type Manifest struct {
	Version int    `yaml:"version"`
	Tools   []Tool `yaml:"tools"`
}

// Tool describes one entry in the manifest's tools list.
type Tool struct {
	ID         string  `yaml:"id"`
	Name       string  `yaml:"name,omitempty"`
	Optional   bool    `yaml:"optional,omitempty"`
	MinVersion string  `yaml:"min_version,omitempty"`
	Detect     Detect  `yaml:"detect"`
	// Install block is preserved but unused by alpha.1's doctor.
	Install    yaml.Node `yaml:"install,omitempty"`
}

// Detect describes how to find a tool and parse its version.
type Detect struct {
	Command      string `yaml:"command"`
	VersionFlag  string `yaml:"version_flag,omitempty"`
	VersionRegex string `yaml:"version_regex,omitempty"`
}

// LoadDefault returns the embedded manifest unless $CA_BOOTSTRAP_MANIFEST
// is set, in which case it loads from that path.
func LoadDefault() (*Manifest, error) {
	if override := os.Getenv("CA_BOOTSTRAP_MANIFEST"); override != "" {
		return Load(override)
	}
	return parseAndValidate(embeddedManifest, "<embedded>")
}

// Load reads the manifest at the given filesystem path.
func Load(path string) (*Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("%w: %s", ErrNotFound, path)
		}
		return nil, fmt.Errorf("read manifest %s: %w", path, err)
	}
	return parseAndValidate(data, path)
}

func parseAndValidate(data []byte, source string) (*Manifest, error) {
	var m Manifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("manifest parse error (%s): %w", source, err)
	}
	if m.Version == 0 {
		return nil, fmt.Errorf("manifest missing required 'version' field (%s)", source)
	}
	if m.Version != 1 {
		return nil, fmt.Errorf("unsupported manifest version %d (%s); only v1 is supported", m.Version, source)
	}
	if len(m.Tools) == 0 {
		return nil, fmt.Errorf("manifest missing required 'tools' list (%s)", source)
	}
	seen := make(map[string]bool)
	for i, t := range m.Tools {
		if t.ID == "" {
			return nil, fmt.Errorf("tool at index %d: missing required 'id'", i)
		}
		if seen[t.ID] {
			return nil, fmt.Errorf("duplicate tool id: %s", t.ID)
		}
		seen[t.ID] = true
		if t.MinVersion != "" {
			if !semverRegex.MatchString(t.MinVersion) {
				return nil, fmt.Errorf("tool %s: invalid min_version %q", t.ID, t.MinVersion)
			}
		}
		if t.Detect.Command == "" {
			return nil, fmt.Errorf("tool %s: missing required detect.command", t.ID)
		}
	}
	return &m, nil
}

var semverRegex = regexp.MustCompile(`^\d+\.\d+\.\d+(?:[-+][\w.]+)?$`)

// defaultContains is a substring helper exported for tests in this
// package (case-insensitive).
func defaultContains(haystack, needle string) bool {
	return strings.Contains(strings.ToLower(haystack), strings.ToLower(needle))
}
```

- [ ] **Step 6: Run unit tests — verify GREEN**

```bash
go get gopkg.in/yaml.v3
go mod tidy
go test ./internal/manifest/... -v 2>&1 | tail -20
```

Expected: all `TestLoad_*` pass.

- [ ] **Step 7: Run acceptance tests — confirm doctor tests still RED**

```bash
go test -tags acceptance ./tests/acceptance/... 2>&1 | tail -10
```

Expected: TestVersion still PASSES, 6 doctor tests still FAIL (doctor subcommand not yet registered).

- [ ] **Step 8: Update tutorial chapter 6**

"GREEN tests 6 & 7 — the manifest loader." Cover: `//go:embed` semantics (the `all:` prefix; what happens at build time), `yaml.Node` for fields we want to preserve but not parse strictly, ordered validation (id presence before semver validity), and `errors.Is` vs string-matching for `ErrNotFound`.

- [ ] **Step 9: Commit**

```bash
git add internal/manifest/ docs/tutorials/tdd-walkthrough.md go.mod go.sum
git commit -S -m "$(cat <<'EOF'
feat(manifest): YAML load + schema validation + embed

Implements internal/manifest per spec §7. Embeds manifest/tools.yaml
at build time via go:embed. $CA_BOOTSTRAP_MANIFEST overrides for
tests / custom manifests. 6 validation rules from spec §7.1
implemented and unit-tested with fixture-per-rule.

Doctor subcommand still pending — these tests won't GREEN the
acceptance suite until Task 10 wires Load into doctor.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 6.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7 — Detection interface + semver parse

**Files:**
- Create: `internal/detect/detect.go`
- Create: `internal/detect/version_parse.go`
- Create: `internal/detect/version_parse_test.go`
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 7)

**Branch:** continue on `feat/alpha-1-impl`

- [ ] **Step 1: Write `version_parse_test.go` FIRST** (table-driven for all version-compare cases)

```go
package detect

import "testing"

func TestVersionAtLeast(t *testing.T) {
	cases := []struct {
		name     string
		got, min string
		want     bool
	}{
		{"equal",          "1.0.0",  "1.0.0",  true},
		{"got higher",     "1.0.1",  "1.0.0",  true},
		{"got lower",      "0.9.9",  "1.0.0",  false},
		{"major diff",     "2.0.0",  "1.9.9",  true},
		{"two-part got",   "1.21",   "1.20.0", true},  // common: `go version` reports "go1.21"
		{"prerelease ok",  "1.0.0-beta.1", "1.0.0", true},  // treat as satisfying
		{"empty min",      "1.2.3",  "",       true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := VersionAtLeast(tc.got, tc.min)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Errorf("VersionAtLeast(%q, %q) = %v, want %v", tc.got, tc.min, got, tc.want)
			}
		})
	}
}

func TestExtractVersion(t *testing.T) {
	cases := []struct {
		name, raw, regex, want string
	}{
		{"go", "go version go1.21.5 darwin/arm64", `go(\d+\.\d+(?:\.\d+)?)`, "1.21.5"},
		{"git", "git version 2.43.0", `(\d+\.\d+\.\d+)`, "2.43.0"},
		{"default regex none", "v3.2.1\n", "", "3.2.1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ExtractVersion(tc.raw, tc.regex)
			if got != tc.want {
				t.Errorf("ExtractVersion(%q, %q) = %q, want %q", tc.raw, tc.regex, got, tc.want)
			}
		})
	}
}
```

- [ ] **Step 2: Run — verify RED**

```bash
go test ./internal/detect/...
```

Expected: build error (functions undefined).

- [ ] **Step 3: Create `internal/detect/detect.go`** (interface only)

```go
// Package detect probes the host for installed tools and parses
// their versions per the manifest schema (spec §8).
package detect

import (
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// Detector probes the host. Implementations are platform-specific:
// detect_unix.go for darwin/linux, detect_windows.go for windows.
type Detector interface {
	Probe(t manifest.Tool) Result
}

// Result captures one tool probe outcome.
type Result struct {
	ID         string
	Found      bool
	Version    string  // semver-ish; "" if Found=false
	VersionRaw string  // raw output, for debugging
	Err        error   // non-nil if probe crashed (binary errored)
}

// Default returns the platform-appropriate Detector. The actual
// implementation is selected via //go:build tags in detect_unix.go
// and detect_windows.go.
func Default() Detector {
	return defaultDetector{}
}

// defaultDetector is filled in per-platform.
type defaultDetector struct{}
```

- [ ] **Step 4: Create `internal/detect/version_parse.go`**

```go
package detect

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

const defaultVersionRegex = `(\d+\.\d+(?:\.\d+)?)`

// ExtractVersion finds the first version-like substring in raw output.
// If pattern is "" it uses defaultVersionRegex.
func ExtractVersion(raw, pattern string) string {
	if pattern == "" {
		pattern = defaultVersionRegex
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return ""
	}
	match := re.FindStringSubmatch(raw)
	if len(match) < 2 {
		return ""
	}
	return strings.TrimSpace(match[1])
}

// VersionAtLeast reports whether got >= min using semver-style compare.
// Empty min is "any version", returns true. Both-part (1.21) and
// three-part (1.21.5) versions are accepted on the `got` side.
func VersionAtLeast(got, min string) (bool, error) {
	if min == "" {
		return true, nil
	}
	g, err := parseTriplet(got)
	if err != nil {
		return false, fmt.Errorf("parse got %q: %w", got, err)
	}
	m, err := parseTriplet(min)
	if err != nil {
		return false, fmt.Errorf("parse min %q: %w", min, err)
	}
	for i := 0; i < 3; i++ {
		if g[i] != m[i] {
			return g[i] > m[i], nil
		}
	}
	return true, nil
}

func parseTriplet(s string) ([3]int, error) {
	// Strip prerelease/build metadata.
	if i := strings.IndexAny(s, "-+"); i >= 0 {
		s = s[:i]
	}
	parts := strings.Split(s, ".")
	if len(parts) > 3 {
		return [3]int{}, fmt.Errorf("too many parts: %q", s)
	}
	var out [3]int
	for i, p := range parts {
		v, err := strconv.Atoi(p)
		if err != nil {
			return [3]int{}, fmt.Errorf("non-numeric component %q: %w", p, err)
		}
		out[i] = v
	}
	return out, nil
}
```

- [ ] **Step 5: Run — verify GREEN for unit tests**

```bash
go test ./internal/detect/... -v 2>&1 | tail -20
```

Expected: all subtests pass.

- [ ] **Step 6: Run all tests — confirm acceptance state unchanged**

```bash
go test ./... && go test -tags acceptance ./tests/acceptance/... 2>&1 | tail -10
```

Expected: unit + integration green; 1 acceptance pass, 6 fail.

- [ ] **Step 7: Update tutorial chapter 7**

"Building the detection interface — testing logic without OS dependencies." Cover: why we split semver-compare from OS-probe (pure functions are pure tests; OS-touching code is more annoying to test), the table-driven test pattern in Go, build-tag-driven polymorphism via the `defaultDetector` stub.

- [ ] **Step 8: Commit**

```bash
git add internal/detect/ docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
feat(detect): Detector interface + semver compare + version regex

Establishes the platform-polymorphic surface (per-OS implementations
land in Tasks 8-9). All non-OS logic (regex extract, semver compare)
is pure functions with table-driven unit tests.

VersionAtLeast handles 2- and 3-part versions on the LHS so
`go version` output ("go1.21") works against a min "1.21.0".

tutorial: docs/tutorials/tdd-walkthrough.md chapter 7.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8 — `detect_unix.go` (Darwin + Linux probe)

**Files:**
- Create: `internal/detect/detect_unix.go` (`//go:build darwin || linux`)
- Create: `internal/detect/detect_unix_test.go` (`//go:build darwin || linux`)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 8)

**Branch:** continue on `feat/alpha-1-impl`

- [ ] **Step 1: Write `detect_unix_test.go` FIRST**

```go
//go:build darwin || linux

package detect

import (
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

func TestProbe_GoBinary(t *testing.T) {
	d := defaultDetector{}
	r := d.Probe(manifest.Tool{
		ID:   "go",
		Name: "Go",
		Detect: manifest.Detect{
			Command:      "go",
			VersionFlag:  "version",
			VersionRegex: `go(\d+\.\d+(?:\.\d+)?)`,
		},
	})
	if r.Err != nil {
		t.Fatalf("unexpected probe error: %v", r.Err)
	}
	if !r.Found {
		t.Errorf("expected go to be found")
	}
	if r.Version == "" {
		t.Errorf("expected non-empty version")
	}
}

func TestProbe_MissingBinary(t *testing.T) {
	d := defaultDetector{}
	r := d.Probe(manifest.Tool{
		ID:     "xyzzy-nonexistent",
		Detect: manifest.Detect{Command: "xyzzy-nonexistent"},
	})
	if r.Err != nil {
		t.Errorf("missing binary should NOT be an error: %v", r.Err)
	}
	if r.Found {
		t.Errorf("expected xyzzy-nonexistent NOT to be found")
	}
}
```

- [ ] **Step 2: Run — verify RED**

```bash
go test ./internal/detect/...
```

Expected: `Probe` undefined on `defaultDetector`.

- [ ] **Step 3: Create `internal/detect/detect_unix.go`**

```go
//go:build darwin || linux

package detect

import (
	"errors"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

// Probe attempts to find the tool's binary on PATH and parse its version.
// Missing-on-PATH is not an error — it's a normal Found=false result.
// Other failures (binary crashes, hangs) are returned via Result.Err.
func (defaultDetector) Probe(t manifest.Tool) Result {
	r := Result{ID: t.ID}

	if _, err := exec.LookPath(t.Detect.Command); err != nil {
		// Not found on PATH — clean signal, not an error.
		return r
	}

	versionFlag := t.Detect.VersionFlag
	if versionFlag == "" {
		versionFlag = "--version"
	}
	cmd := exec.Command(t.Detect.Command, versionFlag)
	out, err := cmd.CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			// Failed to even start the process — actual error.
			r.Err = err
			return r
		}
		// Exit non-zero is OK for version probes — some tools do that.
		// Fall through with the output we did get.
	}
	r.Found = true
	r.VersionRaw = strings.TrimSpace(string(out))
	r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
	return r
}
```

- [ ] **Step 4: Run — verify GREEN**

```bash
go test ./internal/detect/... -v 2>&1 | tail -15
```

Expected: both new tests pass; all existing tests still pass.

- [ ] **Step 5: Run acceptance tests — still 1/7 pass**

```bash
go test -tags acceptance ./tests/acceptance/... 2>&1 | tail -10
```

Expected: TestVersion passes; 6 doctor tests still fail (doctor subcommand not yet wired). This is correct — Task 10 wires it.

- [ ] **Step 6: Update tutorial chapter 8**

"Probing the host on Unix — exec.LookPath + CombinedOutput." Cover: why `LookPath` is the canonical "is it installed?" check, the subtle distinction between "missing on PATH" (Found=false, no error) and "tool exists but crashed" (Found=true with Err), and why `CombinedOutput` is right for version probes (some tools print to stderr).

- [ ] **Step 7: Commit**

```bash
git add internal/detect/detect_unix.go internal/detect/detect_unix_test.go docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
feat(detect): Unix probe — exec.LookPath + version flag dispatch

Implements defaultDetector.Probe for darwin+linux. PATH lookup via
exec.LookPath; version via CombinedOutput (some tools print version
to stderr). Missing-on-PATH is Found=false with no error; probe
crashes propagate via Result.Err.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 8.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9 — `detect_windows.go` (PATH + winget fallback)

**Files:**
- Create: `internal/detect/detect_windows.go` (`//go:build windows`)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 9)

**Branch:** continue on `feat/alpha-1-impl`

Note: Windows-specific unit tests run only on Windows hosts. On macOS/Linux dev boxes we verify the code compiles via `GOOS=windows go vet`.

- [ ] **Step 1: Create `internal/detect/detect_windows.go`**

```go
//go:build windows

package detect

import (
	"errors"
	"os/exec"
	"strings"

	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

func (defaultDetector) Probe(t manifest.Tool) Result {
	r := Result{ID: t.ID}

	// Primary: PATH lookup, same as unix.
	if path, err := exec.LookPath(t.Detect.Command); err == nil {
		return runVersion(t, r, path)
	}
	// Fallback: probe winget for the manifest's winget id, if present.
	// (For alpha.1, install: blocks aren't read, so the winget fallback
	// just looks up by the literal `command` name. Tasks in alpha.2+
	// may parse install.windows.winget for a more accurate id.)
	if wingetAvailable() && wingetHasPackage(t.Detect.Command) {
		// Found via winget but not on PATH — common for GUI apps and
		// some store-installed tools.
		r.Found = true
		// We can't run version flag for things not on PATH; report empty
		// Version with a raw note. Doctor's display logic must tolerate
		// Found=true + Version="" (treated as "present, version unknown").
		r.VersionRaw = "winget: present (not on PATH)"
		return r
	}
	return r
}

func runVersion(t manifest.Tool, r Result, path string) Result {
	versionFlag := t.Detect.VersionFlag
	if versionFlag == "" {
		versionFlag = "--version"
	}
	cmd := exec.Command(path, versionFlag)
	out, err := cmd.CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			r.Err = err
			return r
		}
	}
	r.Found = true
	r.VersionRaw = strings.TrimSpace(string(out))
	r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
	return r
}

func wingetAvailable() bool {
	_, err := exec.LookPath("winget")
	return err == nil
}

func wingetHasPackage(id string) bool {
	cmd := exec.Command("winget", "list", "--id", id, "--exact")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return false
	}
	// winget list exits 0 even on no-match; check output text.
	return !strings.Contains(string(out), "No installed package found")
}
```

- [ ] **Step 2: Cross-compile-check from dev box**

```bash
GOOS=windows go vet ./...
GOOS=windows go build -o /tmp/ca-bootstrap.exe ./cmd/ca-bootstrap && rm -f /tmp/ca-bootstrap.exe
```

Expected: no errors. (Real test runs land on Windows CI in Task 12.)

- [ ] **Step 3: Update tutorial chapter 9**

"Probing the host on Windows — when PATH isn't enough." Cover: the winget fallback rationale (Microsoft Store apps and some installers put binaries outside PATH), the Found=true + Version=empty state (presence known, version unknown), and how downstream display logic handles it.

- [ ] **Step 4: Commit**

```bash
git add internal/detect/detect_windows.go docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
feat(detect): Windows probe — PATH + winget fallback

Mirrors detect_unix.go but adds a winget-list fallback for tools that
Microsoft Store / installer scripts place outside PATH. A winget-only
hit reports Found=true with empty Version and a raw note; doctor
must display this as "present, version unknown."

GOOS=windows go vet passes on dev box; real CI lands in Task 12.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 9.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10 — `doctor` subcommand (GREEN tests 2, 3, 4, 5)

**Files:**
- Create: `internal/cli/doctor.go`
- Create: `internal/cli/doctor_test.go` (integration tests with a stub Detector)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 10)

**Branch:** continue on `feat/alpha-1-impl`

- [ ] **Step 1: Re-confirm RED — 4 doctor tests still fail**

```bash
go test -tags acceptance ./tests/acceptance/... 2>&1 | tail -10
```

Expected: TestVersion + the two ManifestError tests work via stderr matching (parser/loader done), but the 4 "real doctor flow" tests still RED because the subcommand isn't registered.

- [ ] **Step 2: Write `doctor_test.go`** with a stub Detector (integration test, no OS probe)

```go
package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

type stubDetector struct {
	results map[string]detect.Result
}

func (s stubDetector) Probe(t manifest.Tool) detect.Result {
	if r, ok := s.results[t.ID]; ok {
		return r
	}
	return detect.Result{ID: t.ID, Found: false}
}

func TestRunDoctor_ClassifiesResults(t *testing.T) {
	m := &manifest.Manifest{Version: 1, Tools: []manifest.Tool{
		{ID: "ok-tool",   Detect: manifest.Detect{Command: "ok-tool"},   MinVersion: "1.0.0"},
		{ID: "drift-tool",Detect: manifest.Detect{Command: "drift-tool"},MinVersion: "2.0.0"},
		{ID: "missing-required", Detect: manifest.Detect{Command: "missing-required"}},
		{ID: "missing-optional", Detect: manifest.Detect{Command: "missing-optional"}, Optional: true},
	}}
	stub := stubDetector{results: map[string]detect.Result{
		"ok-tool":    {ID: "ok-tool",    Found: true,  Version: "1.5.0"},
		"drift-tool": {ID: "drift-tool", Found: true,  Version: "1.0.0"},
	}}
	var out bytes.Buffer
	exit := runDoctor(&out, m, stub)
	if exit != 2 {
		t.Errorf("expected exit 2 (drift), got %d", exit)
	}
	s := out.String()
	for _, want := range []string{"✓ ok-tool", "✗ drift-tool", "✗ missing-required", "⚠ missing-optional", "1 ok", "2 drift", "1 missing-optional"} {
		if !strings.Contains(s, want) {
			t.Errorf("doctor output missing %q. got:\n%s", want, s)
		}
	}
}

func TestRunDoctor_AllOK_ExitsZero(t *testing.T) {
	m := &manifest.Manifest{Version: 1, Tools: []manifest.Tool{
		{ID: "tool-a", Detect: manifest.Detect{Command: "tool-a"}},
	}}
	stub := stubDetector{results: map[string]detect.Result{
		"tool-a": {ID: "tool-a", Found: true, Version: "1.0.0"},
	}}
	var out bytes.Buffer
	exit := runDoctor(&out, m, stub)
	if exit != 0 {
		t.Errorf("expected exit 0, got %d", exit)
	}
}
```

- [ ] **Step 3: Run — verify RED**

```bash
go test ./internal/cli/...
```

Expected: `runDoctor` undefined.

- [ ] **Step 4: Create `internal/cli/doctor.go`**

```go
package cli

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/ChannelAssist/ca-bootstrap/internal/detect"
	"github.com/ChannelAssist/ca-bootstrap/internal/manifest"
)

var doctorCmd = &cobra.Command{
	Use:   "doctor",
	Short: "Diagnose installed tooling against the manifest (read-only)",
	RunE: func(cmd *cobra.Command, args []string) error {
		m, err := manifest.LoadDefault()
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		exit := runDoctor(os.Stdout, m, detect.Default())
		os.Exit(exit)
		return nil // unreachable
	},
}

func init() {
	rootCmd.AddCommand(doctorCmd)
}

// runDoctor probes every tool in the manifest, prints a report to w,
// and returns the exit code per spec §6.3:
//   0 - clean
//   2 - drift (required tool missing or below min)
//   1 - reserved for system errors (handled by the cobra RunE)
func runDoctor(w io.Writer, m *manifest.Manifest, d detect.Detector) int {
	fmt.Fprintln(w, "Checking installed tooling against manifest/tools.yaml...")
	fmt.Fprintln(w)

	var ok, drift, missingOptional int
	for _, tool := range m.Tools {
		r := d.Probe(tool)
		switch classify(tool, r) {
		case classOK:
			fmt.Fprintf(w, "  ✓ %s\t%s\t(manifest min: %s)\n", tool.ID, r.Version, tool.MinVersion)
			ok++
		case classDrift:
			fmt.Fprintf(w, "  ✗ %s\t%s\t(manifest min: %s)   → install %s\n", tool.ID, displayVersion(r), tool.MinVersion, tool.ID)
			drift++
		case classMissingOptional:
			fmt.Fprintf(w, "  ⚠ %s\tnot found                       → optional, install via brew\n", tool.ID)
			missingOptional++
		}
	}
	fmt.Fprintln(w)
	fmt.Fprintf(w, "%d tools checked: %d ok, %d drift, %d missing-optional\n",
		len(m.Tools), ok, drift, missingOptional)
	if drift > 0 {
		return 2
	}
	return 0
}

type classification int

const (
	classOK classification = iota
	classDrift
	classMissingOptional
)

func classify(t manifest.Tool, r detect.Result) classification {
	if !r.Found {
		if t.Optional {
			return classMissingOptional
		}
		return classDrift
	}
	if t.MinVersion == "" {
		return classOK
	}
	ok, err := detect.VersionAtLeast(r.Version, t.MinVersion)
	if err != nil || !ok {
		if t.Optional {
			return classMissingOptional
		}
		return classDrift
	}
	return classOK
}

func displayVersion(r detect.Result) string {
	if r.Version == "" {
		return "not found"
	}
	return r.Version
}
```

- [ ] **Step 5: Run unit tests — verify GREEN**

```bash
go test ./internal/cli/... -v 2>&1 | tail -10
```

Expected: both new tests pass.

- [ ] **Step 6: Run acceptance tests — verify ALL 7 GREEN**

```bash
go test -tags acceptance ./tests/acceptance/... -v 2>&1 | tail -20
```

Expected: 7/7 PASS. **The discipline gate.** If any are still red, stop and debug — do not move on.

- [ ] **Step 7: Run full test suite — clean**

```bash
go vet ./... && go test ./... && go test -tags acceptance ./tests/acceptance/...
echo "all green: $?"
```

Expected: `all green: 0`.

- [ ] **Step 8: Update tutorial chapter 10**

"GREEN remaining tests — the doctor subcommand." This is the chapter that captures the climactic moment: 7/7 green for the first time. Cover: the classification helper pattern (small enum + switch, easy to unit-test), `io.Writer` injection in `runDoctor` (lets us test without spawning a process), why `os.Exit` in the cobra RunE is acceptable here (we deliberately want to control the exit code from non-error code paths).

- [ ] **Step 9: Commit**

```bash
git add internal/cli/doctor.go internal/cli/doctor_test.go docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
feat(cli): doctor subcommand — all 7 acceptance tests green

Implements doctor per spec §6: loads manifest via LoadDefault (env
override or embedded), probes each tool via the platform Detector,
classifies each as ok/drift/missing-optional, formats the report,
exits 0 / 2 / 1.

The runDoctor function takes an io.Writer and Detector so it's
testable without spawning subprocesses (see doctor_test.go).

After this commit: `go test -tags acceptance ./tests/...` is 7/7 GREEN.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 10 — first
fully-green moment.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

End of the implementation PR — push branch + open the second implementation PR per the strategy table. Title:

```
feat(alpha-1): implement version + doctor; all 7 acceptance tests green (AB#<IMPL-PBI>)
```

---

## Task 11 — Refactor pass (REFACTOR phase)

**Files:**
- Modify: any of the above as needed; no new functionality
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 11)

**Branch:** new `refactor/alpha-1-cleanup` (or continue on impl branch as a follow-up commit)

- [ ] **Step 1: Run `golangci-lint` and address any findings**

```bash
golangci-lint run ./... 2>&1 | head -30
```

- [ ] **Step 2: Identify duplication candidates**

Look at:
- `detect_unix.go` and `detect_windows.go` — the `runVersion` block is duplicated. Consider extracting `runVersionCmd(path, flag, regex string) (raw, parsed string, err error)` into shared `version_parse.go`.
- Glyph constants (`✓` / `✗` / `⚠`) appearing as literals in `doctor.go` — extract into const block for ASCII fallback (Task spec §6.2 mentions `CA_BOOTSTRAP_ASCII` env var).

- [ ] **Step 3: For each refactor:**

```bash
# Make change
go test ./... && go test -tags acceptance ./tests/acceptance/...
# Confirm STILL GREEN — refactor must not change behavior
```

- [ ] **Step 4: ASCII glyph fallback** (was deferred from Task 10)

In `doctor.go`, replace literal glyphs with:

```go
var (
	glyphOK   = "✓"
	glyphFail = "✗"
	glyphWarn = "⚠"
)

func init() {
	if os.Getenv("CA_BOOTSTRAP_ASCII") != "" {
		glyphOK, glyphFail, glyphWarn = "[ok]", "[FAIL]", "[warn]"
	}
}
```

(No new acceptance test for the ASCII path in alpha.1 — it's a belt-and-braces. Consider adding one in alpha.2.)

- [ ] **Step 5: Update tutorial chapter 11**

"REFACTOR — making it right after making it work." Cover: the discipline of not changing behavior, the green test suite as a safety net, ASCII fallback as a refactor-shaped feature (no new tests; existing tests still pass via the default branch), and when to split vs inline.

- [ ] **Step 6: Commit (one logical refactor per commit; keep bisectable)**

```bash
git add ... docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
refactor(detect|cli): extract version-cmd helper; add ASCII glyph fallback

No behavior change. All 7 acceptance tests + unit tests stay green.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 11.

Refs: AB#<NEW-IMPL-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12 — CI workflow (`.github/workflows/ci.yml`)

**Files:**
- Create: `.github/workflows/ci.yml`
- Delete: any leftover PS-era workflow files at this path (move to `legacy/.github/` if not already)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 12)

**Branch:** `chore/alpha-1-ci-release` off `dev`

- [ ] **Step 1: Verify legacy workflows are out of the way**

```bash
ls -la .github/workflows/
ls -la legacy/.github/workflows/ 2>/dev/null
```

If any PS-era workflows still live at `.github/workflows/`, `git mv` them to `legacy/.github/workflows/` first.

- [ ] **Step 2: Create `.github/workflows/ci.yml`**

```yaml
name: Ci
on:
  push:
    branches: [dev]
  pull_request:

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.23'
          cache: true
      - name: go vet
        run: go vet ./...
      - name: go test (unit + integration)
        run: go test -race -count=1 ./...
      - name: go test (acceptance)
        if: matrix.os != 'windows-latest'   # Windows acceptance tests run in release.yml
        run: go test -tags acceptance -count=1 ./tests/acceptance/...

  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.23'
      - uses: golangci/golangci-lint-action@v6
        with:
          version: latest
```

- [ ] **Step 3: Verify locally one more time**

```bash
go vet ./... && go test -race -count=1 ./... && go test -tags acceptance -count=1 ./tests/acceptance/...
```

Expected: all green locally before pushing.

- [ ] **Step 4: Update tutorial chapter 12**

"Setting up CI — the safety net that catches what humans miss." Cover: the matrix strategy, why `fail-fast: false` (you want to see ALL platforms fail, not bail on first red), why `-race` (Go's race detector catches goroutine bugs in tests; cheap insurance), and why acceptance tests are skipped on Windows in `ci.yml` (slow Windows runners + cross-compile checks in release.yml are sufficient).

- [ ] **Step 5: Commit, push, watch the FIRST CI run go green**

```bash
git add .github/workflows/ci.yml docs/tutorials/tdd-walkthrough.md
git commit -S -m "$(cat <<'EOF'
ci(go): add ci.yml — vet + unit/integration/acceptance on 3 OS + lint

Matrix: ubuntu-latest, macos-latest, windows-latest. Race detector
enabled. Acceptance tests run on Linux + macOS in CI; Windows
acceptance runs in release.yml to avoid the slow Windows runner on
every PR.

golangci-lint on Linux only — its findings are platform-independent.

tutorial: docs/tutorials/tdd-walkthrough.md chapter 12.

Refs: AB#<NEW-CI-PBI>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin chore/alpha-1-ci-release
gh pr create --base dev --title "ci: add Go ci.yml workflow (AB#<NEW>)" --body "..."
# Wait for CI run; address any failures.
```

---

## Task 13 — Release workflow (`.github/workflows/release.yml`)

**Files:**
- Create: `.github/workflows/release.yml`
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 13)

**Branch:** continue on `chore/alpha-1-ci-release` (or new PR if Task 12 already merged)

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release
on:
  push:
    tags: ['v[0-9]*']

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { runs-on: ubuntu-latest,  goos: linux,   goarch: amd64, ext: tar.gz }
          - { runs-on: macos-latest,   goos: darwin,  goarch: arm64, ext: tar.gz }
          - { runs-on: macos-latest,   goos: darwin,  goarch: amd64, ext: tar.gz }
          - { runs-on: windows-latest, goos: windows, goarch: amd64, ext: zip    }
          - { runs-on: windows-latest, goos: windows, goarch: arm64, ext: zip    }
    runs-on: ${{ matrix.runs-on }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: '1.23' }

      - name: Build
        shell: bash
        env:
          GOOS:   ${{ matrix.goos }}
          GOARCH: ${{ matrix.goarch }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          SHA="${GITHUB_SHA::7}"
          NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          OUT="ca-bootstrap"
          [ "$GOOS" = windows ] && OUT="${OUT}.exe"
          mkdir -p dist
          go build \
            -ldflags "-X main.Version=$VERSION -X main.Commit=$SHA -X main.BuildTime=$NOW" \
            -o "dist/$OUT" ./cmd/ca-bootstrap

      - name: Native acceptance smoke
        if: matrix.goos != 'linux' || matrix.runs-on == 'ubuntu-latest'
        shell: bash
        run: go test -tags acceptance -count=1 ./tests/acceptance/...

      - name: Archive
        shell: bash
        env:
          GOOS:   ${{ matrix.goos }}
          GOARCH: ${{ matrix.goarch }}
          EXT:    ${{ matrix.ext }}
        run: |
          VERSION="${GITHUB_REF_NAME}"
          BASE="ca-bootstrap_${VERSION}_${GOOS}_${GOARCH}"
          cd dist
          if [ "$EXT" = zip ]; then
            7z a "../$BASE.zip" ca-bootstrap.exe LICENSE 2>/dev/null || zip "../$BASE.zip" ca-bootstrap.exe ../LICENSE
          else
            tar -czf "../$BASE.tar.gz" ca-bootstrap ../LICENSE
          fi
          cd ..

      - uses: actions/upload-artifact@v4
        with:
          name: ca-bootstrap-${{ matrix.goos }}-${{ matrix.goarch }}
          path: ca-bootstrap_*

  release:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { merge-multiple: true }
      - name: Compute SHA256SUMS
        run: sha256sum ca-bootstrap_* > SHA256SUMS
      - name: Create release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          PRERELEASE_FLAG=""
          case "$GITHUB_REF_NAME" in *-*) PRERELEASE_FLAG="--prerelease" ;; esac
          gh release create "$GITHUB_REF_NAME" \
            $PRERELEASE_FLAG \
            --title "ca-bootstrap $GITHUB_REF_NAME" \
            --notes-file CHANGELOG.md \
            ca-bootstrap_* SHA256SUMS
```

- [ ] **Step 2: Update tutorial chapter 13**

"Release pipeline — every tag pushes 5 binaries." Cover: the build matrix shape, why we use bash on all OS (the `shell: bash` line — Windows runners have Git Bash bundled, so this is consistent), `--prerelease` detection from the tag name (any tag with `-` is pre-release), the goreleaser-style asset-name convention, and the deferred signing.

- [ ] **Step 3: Commit + push + open PR**

```bash
git add .github/workflows/release.yml docs/tutorials/tdd-walkthrough.md
git commit -S -m "release(workflow): 5-platform build matrix on tag push (AB#<NEW>)"
# Open PR; CI will run ci.yml only — release.yml needs an actual tag push.
```

---

## Task 14 — README + CHANGELOG + VERSION

**Files:**
- Modify: `README.md` (root) — replace PS install instructions with Go-era ones
- Modify: `CHANGELOG.md` — add `[2.0.0-alpha.1]` section
- Modify: `VERSION` — `2.0.0-alpha.1`
- Modify: `docs/collaboration-workflow.html` — update phase pills (alpha.1 → DONE; alpha.2 → IN PROGRESS or remove if not yet started)
- Modify: `docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md` — update Status to "Shipped"
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 14)

**Branch:** new `release/v2.0.0-alpha.1` off `dev`

- [ ] **Step 1: Update `VERSION`** to exactly `2.0.0-alpha.1` (one line, no newline at end? match existing convention — check by `cat -A VERSION` before this work).

- [ ] **Step 2: Rewrite README's "Quick start" section** for the Go era

Replace the PowerShell install one-liner block (which the pivot doc deprecated). New section:

```markdown
### Windows / macOS / Linux

Download the binary for your platform from
[GitHub Releases](https://github.com/ChannelAssist/ca-bootstrap/releases/latest)
and put it on your PATH:

```bash
# macOS (Apple Silicon)
curl -L https://github.com/ChannelAssist/ca-bootstrap/releases/latest/download/ca-bootstrap_2.0.0-alpha.1_darwin_arm64.tar.gz | tar -xz
sudo mv ca-bootstrap /usr/local/bin/
```

```powershell
# Windows (amd64)
# 1. Download ca-bootstrap_2.0.0-alpha.1_windows_amd64.zip from the latest release
# 2. Right-click the .zip → Properties → Unblock → Apply  (SmartScreen)
# 3. Extract; move ca-bootstrap.exe to a folder on your PATH
```

Verify:
```bash
ca-bootstrap version
ca-bootstrap doctor
```

> **Note:** alpha and beta releases are unsigned. On Windows you'll see a SmartScreen warning the first time — that's expected. v2.0.0 final ships signed.
```

- [ ] **Step 3: Add `CHANGELOG.md` entry under `[Unreleased]`**

```markdown
## [2.0.0-alpha.1] - 2026-MM-DD

Initial Go-rewrite release. PowerShell implementation archived at tag `legacy/v1.9.0`.

### Added

- **`ca-bootstrap` binary** for Windows (amd64/arm64), macOS (arm64/amd64), Linux (amd64).
- **`ca-bootstrap version`** — prints semver, build commit, build timestamp.
- **`ca-bootstrap doctor`** — read-only inventory of installed tools against `manifest/tools.yaml` (embedded). Exits 0 (clean), 2 (drift), or 1 (system error).
- **`$CA_BOOTSTRAP_MANIFEST` env var** — override the embedded manifest with a filesystem path (tests, custom inventories).

### Changed

- **Implementation language: PowerShell → Go.** See `docs/specs/2026-05-25-go-rewrite-pivot.md` for rationale.

### Removed

- All PowerShell subcommands (`setup`, `repair`, `undo`) are temporarily absent — they land in alphas 2–4. The PS implementation at `legacy/v1.9.0` remains usable in the interim.

[2.0.0-alpha.1]: https://github.com/ChannelAssist/ca-bootstrap/compare/v1.9.0...v2.0.0-alpha.1
```

- [ ] **Step 4: Update the collaboration HTML** per the sync rule

Edit `docs/collaboration-workflow.html`:
- Status pills row: Phase F → "DONE" once tag pushes and release ships
- alpha.1 release matrix: add download badges if you want a flair, or leave as-is

- [ ] **Step 5: Update spec doc Status**

In `docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`, change the Status frontmatter line from `Draft → pending Peter review` to `Shipped 2026-MM-DD as v2.0.0-alpha.1`.

- [ ] **Step 6: Update tutorial chapter 14**

"Shipping — the README rewrite, the CHANGELOG entry, the version bump." Cover: documentation-as-code (these are the user-visible deltas), why we sync the HTML companion at release time per the standing rule, and how this PR sets up the tag-push event for `release.yml`.

- [ ] **Step 7: Commit and open the release PR**

```bash
git add README.md CHANGELOG.md VERSION docs/collaboration-workflow.html docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md docs/tutorials/tdd-walkthrough.md
git commit -S -m "release: v2.0.0-alpha.1 — Go rewrite, doctor + version (AB#<NEW>)"
git push -u origin release/v2.0.0-alpha.1
gh pr create --base dev --title "release: v2.0.0-alpha.1" ...
```

---

## Task 15 — Tag and ship

- [ ] **Step 1: Merge the release PR to dev**

- [ ] **Step 2: From dev, tag the merge commit**

```bash
git checkout dev && git pull --ff-only origin dev
git tag -s v2.0.0-alpha.1 -m "$(cat <<'EOF'
ca-bootstrap v2.0.0-alpha.1

First Go-rewrite release. doctor + version subcommands.

5-platform binaries published via release.yml.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3: Push the tag — watch release.yml fire**

```bash
git push origin v2.0.0-alpha.1
gh run watch
```

- [ ] **Step 4: Verify the release**

```bash
gh release view v2.0.0-alpha.1
# Expect 5 binaries + SHA256SUMS + prerelease=true
```

- [ ] **Step 5: Smoke-test on a real Windows box**

Per spec §13 acceptance criterion #1: install the Windows amd64 binary, click through SmartScreen, run `ca-bootstrap doctor`. Confirm exit code per the local PATH state.

- [ ] **Step 6: Tutorial chapter 15 — the finale**

"Shipped." Cover what changed between local "go build" and the released binary (ldflag injection, archive contents, SmartScreen flow), how to verify a release, and what alpha.2 will tackle (setup + interactive prompts + action journal).

- [ ] **Step 7: Engineering journal entry**

Per the rules in `~/.claude/CLAUDE.md` and `~/.claude/MEMORY.md`: write a journal entry in Keystone (`content/journal/2026-q2.md`) via the `/journal` skill. This is a quarter-ending milestone-worthy entry.

---

# Appendix A — `docs/tutorials/tdd-walkthrough.md` skeleton

This is what the tutorial doc looks like AT THE START of Task 1 (Chapter 1 will be the first content; subsequent chapters land in subsequent tasks). Save this exact content when Task 1 Step 6 says "Create the tutorial doc."

```markdown
# Building ca-bootstrap (Go) — a TDD walkthrough

> **For onboarding ChannelAssist developers.**
> This document is the live record of how `ca-bootstrap` v2.0.0-alpha.1 was built. Every command, every test, every commit you see here is real — you can `git checkout` the corresponding commit and reproduce the state.

## How to use this tutorial

- Read top to bottom on first encounter — chapters build on each other.
- Each chapter corresponds to one task in `docs/plans/2026-05-25-go-alpha-1-plan.md`.
- Code blocks are exactly what was run. Expected output is shown where it's pedagogically useful.
- Callouts (`> [Why]`, `> [Gotcha]`) explain reasoning that future-you might wonder about.

## Prerequisites

- Go 1.23+ (`brew install go` / `winget install GoLang.Go`)
- `git`
- Familiarity with Go modules and the command line. No prior cobra experience needed; this tutorial introduces it.
- Read these first: [`docs/specs/2026-05-25-go-rewrite-pivot.md`](../specs/2026-05-25-go-rewrite-pivot.md) (the WHY), [`docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`](../specs/2026-05-25-go-v2-0-alpha-1-spec.md) (the WHAT).

## Background — why TDD here?

Strict TDD (Red → Green → Refactor) for this rewrite is non-negotiable. Three reasons:
1. **Spec-by-example.** The 7 acceptance tests in the spec ARE the alpha.1 contract. If they pass, alpha.1 is done.
2. **Bug class avoidance.** The PowerShell predecessor accumulated a class of stdio/console bugs we kept patching one symptom at a time. Tests-first force us to *think about edge cases before writing code that has to handle them*.
3. **Confidence to delete.** Every test we write is a license to refactor with confidence later. In a tool that touches a user's environment, that matters.

We use **outside-in TDD**: write all 7 acceptance tests first (one big RED phase), then implement smallest-thing-first to GREEN them one at a time, refactoring between greens.

## Chapter index

1. The migration (PS → `legacy/`)
2. Scaffolding the Go module
3. Why fixtures come before tests
4. RED: writing all 7 tests at once
5. GREEN test 1: the smallest possible subcommand
6. GREEN tests 6 & 7: the manifest loader
7. Building the detection interface
8. Probing the host on Unix
9. Probing the host on Windows
10. GREEN remaining tests: the doctor subcommand
11. REFACTOR — making it right after making it work
12. Setting up CI
13. The release pipeline
14. Shipping — the README rewrite, CHANGELOG, VERSION
15. Tag and release

[Each chapter is added in its corresponding task.]
```

---

# Self-review

**Spec coverage check** (every alpha.1 deliverable from the spec has a task):

| Spec section | Covered by | ✓/✗ |
|---|---|---|
| §2 Locked decisions | Reflected in plan header + each task's choices | ✓ |
| §3 Non-goals | Tasks intentionally absent (no setup/repair/undo) | ✓ |
| §4.1 Go module layout | Tasks 1–10 create exactly this layout | ✓ |
| §4.2 Dependencies | Task 2 adds cobra; Task 6 adds yaml.v3 | ✓ |
| §4.3 Build-time injection | Task 2 main.go + Task 13 release.yml ldflags | ✓ |
| §5 `version` spec | Task 5 | ✓ |
| §6 `doctor` spec | Task 10 (with units in 7-9) | ✓ |
| §6.5 Manifest source-of-truth | Task 6 (`//go:embed` + env var override) | ✓ |
| §7 Manifest schema | Task 6 | ✓ |
| §8 OS abstraction | Tasks 7, 8, 9 | ✓ |
| §9 Testing strategy | Tasks 3, 4, plus unit tests in 6, 7, 10 | ✓ |
| §10 Release pipeline | Tasks 12, 13 | ✓ |
| §11 Repository migration | Task 1 | ✓ |
| §13 Acceptance criteria | Verified in Task 10 step 6 (7/7 green) + Task 15 step 4-5 | ✓ |

**Placeholder scan:** `AB#<NEW-MIGRATION-PBI>`, `AB#<NEW-IMPL-PBI>`, `AB#<NEW-CI-PBI>` are deliberate placeholders — file the PBIs and substitute real numbers at execution time (per the pr-metadata-checklist's AB# verification rule).

**Type consistency:** `Detector.Probe`, `manifest.Tool`, `manifest.Detect`, `detect.Result`, `runDoctor(io.Writer, *manifest.Manifest, detect.Detector) int`, `classify(manifest.Tool, detect.Result) classification` — all signatures match across Tasks 6, 7, 8, 9, 10.

---

# Execution

**Plan complete and saved to `docs/plans/2026-05-25-go-alpha-1-plan.md`.** Two execution options:

1. **Subagent-Driven (recommended for an end-to-end run)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Good if you want to maximize my throughput.
2. **Inline Execution** — Execute tasks in this session using `executing-plans`, with checkpoints for your review. Good if you want to see every step live and learn alongside (since this doubles as a TDD tutorial).

**Inline Execution is the right fit for THIS project** because the tutorial doc is part of every task — having me execute inline means the tutorial captures genuine commentary written as the work happens, rather than retrospective narration. The "live record" framing in the tutorial preamble depends on it.

Which approach?
