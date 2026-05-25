# ca-bootstrap v2.0.0-alpha.3 — Implementation Plan

> **For agentic workers:** Use `superpowers:subagent-driven-development` or `superpowers:executing-plans`. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship `ca-bootstrap v2.0.0-alpha.3` — add `repair --target <tool-id>` (install one missing tool per manifest), real OS-level session lock, and journal entries for every install attempt so alpha.4's `undo` can reverse them.

**Architecture:** Two new packages (`internal/install`, `internal/lock`) + extension of `internal/manifest` to parse the `install:` block + new cobra subcommand at `internal/cli/repair.go`. The install dispatcher is platform-polymorphic via build tags (mirrors how `internal/detect` is structured).

**Tech Stack:** Go 1.23+, existing deps only (cobra, yaml.v3, stdlib). No new external deps. `syscall` for file locking.

**Spec reference:** [`docs/specs/2026-05-25-go-v2-0-alpha-3-spec.md`](../specs/2026-05-25-go-v2-0-alpha-3-spec.md).

---

## File structure (new in alpha.3)

| Path | Responsibility | Created in |
|---|---|---|
| `internal/install/install.go` | `Installer` interface + `Result` type | Task 3 |
| `internal/install/install_unix.go` | `//go:build darwin || linux`: brew/apt/dnf/npm/script dispatch | Task 4 |
| `internal/install/install_windows.go` | `//go:build windows`: winget/npm dispatch | Task 5 |
| `internal/install/elevation.go` | "Needs elevation?" heuristic + cross-platform elevate-and-run | Task 6 |
| `internal/install/*_test.go` | Unit tests for dispatch + elevation detection | Tasks 3-6 |
| `internal/lock/lock.go` | `Lock` interface + factory | Task 7 |
| `internal/lock/lock_unix.go` | `//go:build darwin || linux`: `syscall.Flock` | Task 7 |
| `internal/lock/lock_windows.go` | `//go:build windows`: `LockFileEx` via syscall | Task 7 |
| `internal/lock/lock_test.go` | Lock acquire/release/force-unlock tests | Task 7 |
| `internal/manifest/install_schema.go` | New typed parsing for the `install:` block | Task 2 |
| `internal/cli/repair.go` | Cobra `repair` subcommand + `--ForceUnlock` flag | Task 8 |
| `tests/acceptance/acceptance_test.go` | 8 new alpha.3 tests | Task 1 (RED) |
| `tests/acceptance/testdata/repair-*.yaml` | Fixture manifests + unattended configs | Task 1 |
| `docs/tutorials/tdd-walkthrough.md` | Part III, chapters 20-28 | Each task |

---

## Branch and PR strategy

| Branch | Contains | Depends on |
|---|---|---|
| `chore/alpha-3-scaffold-and-red` | Tasks 1-2 (8 failing tests + manifest schema extension + tutorial ch 20-21) | #93 merged or stacked |
| `feat/alpha-3-impl` | Tasks 3-9 (impl + refactor + tutorial ch 22-28) | scaffold PR |

Two PRs after spec is approved.

---

## Task 1 — RED phase: 8 failing acceptance tests + fixtures

**Files:**
- Modify: `tests/acceptance/acceptance_test.go` (append 8 new tests)
- Create: `tests/acceptance/testdata/repair-mock-success.yaml` (manifest with a `mock-success` tool)
- Create: `tests/acceptance/testdata/repair-mock-fail.yaml` (manifest with a `mock-fail` tool)
- Create: `tests/acceptance/testdata/unattended-repair-skip.yaml`
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 20: opens Part III)

**Branch:** `chore/alpha-3-scaffold-and-red` off `feat/alpha-2-impl` (Go module + alpha.2 are required to be present)

- [ ] **Step 1: Fixture manifests** with mock installers (use a `mock` install type that the installer dispatch recognizes for testing — install_test.go uses it to inject canned results)

- [ ] **Step 2: 8 acceptance tests** (full code in commit; sketched here):

```go
func TestRepair_TargetNotInManifest_ExitsOne(t *testing.T) { ... }
func TestRepair_AlreadyInstalled_ExitsZeroNoOp(t *testing.T) { ... }
func TestRepair_HappyPath_InstallsAndVerifies(t *testing.T) { ... }
func TestRepair_InstallFailure_ExitsTwo(t *testing.T) { ... }
func TestRepair_ElevationPromptDeclined_ExitsOneThirty(t *testing.T) { ... }
func TestRepair_ElevationSkipChosen_ExitsTwoWithManual(t *testing.T) { ... }
func TestRepair_LockHeld_ExitsOne(t *testing.T) { ... }
func TestRepair_ForceUnlock_ClearsExistingLock_ExitsZero(t *testing.T) { ... }
```

- [ ] **Step 3: Verify RED** — 8/8 fail because `repair` subcommand doesn't exist yet

- [ ] **Step 4: Tutorial chapter 20** — opens "Part III"; covers the mock-installer testing strategy + why we mock at the `Installer` interface layer (not at `exec.Command`)

- [ ] **Step 5: Commit**

---

## Task 2 — Extend `internal/manifest` to parse `install:` block

**Files:**
- Modify: `internal/manifest/manifest.go` (replace `yaml.Node` install field with typed struct)
- Create: `internal/manifest/install_schema.go` (the typed schema)
- Modify: `internal/manifest/manifest_test.go` (add tests for install parsing)

**Branch:** continue on `chore/alpha-3-scaffold-and-red`

- [ ] **Step 1: Write tests first** — verify a manifest with `install.windows.winget`, `install.macos.brew`, `install.linux.debian.apt`, etc. parses correctly

- [ ] **Step 2: Verify RED** — new tests fail (install fields are `yaml.Node`)

- [ ] **Step 3: Define typed schema** matching the existing manifest:

```go
type InstallSpec struct {
    Windows InstallTarget `yaml:"windows,omitempty"`
    Macos   InstallTarget `yaml:"macos,omitempty"`
    Linux   InstallTarget `yaml:"linux,omitempty"`
    Any     InstallTarget `yaml:"any,omitempty"`
}

type InstallTarget struct {
    Type        string            `yaml:"type"`        // winget, brew, apt, dnf, npm, script, command
    ID          string            `yaml:"id,omitempty"`
    URL         string            `yaml:"url,omitempty"`
    Args        string            `yaml:"args,omitempty"`
    Cask        bool              `yaml:"cask,omitempty"`
    Global      bool              `yaml:"global,omitempty"`
    Classic     bool              `yaml:"classic,omitempty"`
    PostInstall []string          `yaml:"post_install,omitempty"`
    // Linux-specific: debian/rhel sub-keys
    Debian      *InstallTarget    `yaml:"debian,omitempty"`
    Rhel        *InstallTarget    `yaml:"rhel,omitempty"`
}
```

- [ ] **Step 4: Verify GREEN** — manifest parses all 16 tools without error

- [ ] **Step 5: Tutorial chapter 21** — "extending the manifest schema without breaking the embedded data"

- [ ] **Step 6: Commit** (end of scaffold/RED PR)

---

## Task 3 — `Installer` interface + `Result` type

**Files:**
- Create: `internal/install/install.go` (interface only — no platform-specific code)
- Create: `internal/install/install_test.go` (interface tests with stub impls)

**Branch:** new `feat/alpha-3-impl` off `chore/alpha-3-scaffold-and-red`

- [ ] **Step 1: Write tests first**:

```go
type Installer interface {
    Install(t manifest.Tool, opts Options) Result
}

type Options struct {
    Out             io.Writer
    Prompter        prompt.Prompter
    AllowElevation  bool   // false means skip elevated commands
}

type Result struct {
    Tool         string
    Status       Status   // Installed | Failed | Skipped | NotApplicable
    Err          error
    ManualCmd    string   // populated when Status==Skipped
}

type Status int
const (
    Installed Status = iota
    Failed
    Skipped
    NotApplicable  // tool already at target version, no-op
)
```

- [ ] **Steps 2-5:** RED → impl → GREEN → tutorial chapter 22

- [ ] **Step 6: Commit**

---

## Task 4 — Unix installer (`detect_unix.go`)

**Files:**
- Create: `internal/install/install_unix.go` (`//go:build darwin || linux`)
- Create: `internal/install/install_unix_test.go`

**Branch:** continue on `feat/alpha-3-impl`

- [ ] **Step 1: Tests** — table-driven matrix:
  - macOS + brew → constructs `brew install <id>` (with `--cask` if `cask: true`)
  - macOS + brew + post_install → runs post_install commands after main install
  - Linux/debian + apt → constructs `apt-get install -y <id>`
  - Linux/rhel + dnf → constructs `dnf install -y <id>`
  - script type → `curl -fsSL <url> | bash` (or `sh -c "$(curl <url>) $args"`)
  - npm type with global: true → `npm install -g <id>`

- [ ] **Step 2: Test command construction WITHOUT actually running** — use a `dispatchOnly` flag the impl honors so tests can assert on the resulting `exec.Command` shape

- [ ] **Steps 3-5:** RED → impl → GREEN → tutorial chapter 23

- [ ] **Step 6: Commit**

---

## Task 5 — Windows installer

**Files:**
- Create: `internal/install/install_windows.go`
- Tests: cross-compile only (we don't have a Windows host)

**Branch:** continue on `feat/alpha-3-impl`

- [ ] **Step 1: Impl** — winget primary, npm fallback, command type for arbitrary commands

- [ ] **Step 2: Verify `GOOS=windows go vet ./...` and `GOOS=windows go build`** clean

- [ ] **Step 3: Tutorial chapter 24**

- [ ] **Step 4: Commit**

---

## Task 6 — Elevation detection + invocation

**Files:**
- Create: `internal/install/elevation.go`
- Create: `internal/install/elevation_test.go`

**Branch:** continue on `feat/alpha-3-impl`

- [ ] **Step 1: Tests** for `NeedsElevation(InstallTarget) bool`:
  - `type: apt` → true
  - `type: dnf` → true
  - `type: winget` → false (default user scope; true only if `scope: machine` in args)
  - `type: brew` → false
  - `type: npm` + `global: true` → false on macOS/Linux (user-owned prefix), true on systems with system-wide npm
  - `type: script` + url contains "sudo" → true
  - Any command containing `sudo ` → true

- [ ] **Steps 2-5:** RED → impl → GREEN → tutorial chapter 25 — "the elevation rules, made testable"

- [ ] **Step 6: Commit**

---

## Task 7 — Session lock package

**Files:**
- Create: `internal/lock/lock.go` (interface)
- Create: `internal/lock/lock_unix.go` (`syscall.Flock`)
- Create: `internal/lock/lock_windows.go` (`LockFileEx`)
- Create: `internal/lock/lock_test.go`

**Branch:** continue on `feat/alpha-3-impl`

- [ ] **Step 1: Tests** — verify exclusive acquire, second-acquire-blocks, release, ForceUnlock semantics, cleanup on process exit (via `t.TempDir()` + goroutine)

- [ ] **Step 2-5:** RED → impl → GREEN → tutorial chapter 26 — "cross-platform file locking, two ways"

- [ ] **Step 6: Commit**

---

## Task 8 — `repair` subcommand + setup-lock integration → ALL 22 GREEN

**Files:**
- Create: `internal/cli/repair.go` (cobra subcommand)
- Modify: `internal/cli/setup.go` (wrap in lock acquisition)
- Create: `internal/cli/repair_test.go` (integration tests with stub Installer)

**Branch:** continue on `feat/alpha-3-impl`

- [ ] **Step 1: Wire** cobra subcommand: flags `--target <id>`, `--ForceUnlock`, `--unattended --config`

- [ ] **Step 2: Pre-install detection** — if `doctor` says tool is already at-or-above min, exit 0 with "already installed" message (no journal entry)

- [ ] **Step 3: Install dispatch** — call `Installer.Install(tool, opts)` with prompter + writer

- [ ] **Step 4: Post-install verification** — run `detect.Probe(tool)` again; if still drift, exit 2

- [ ] **Step 5: Manual-install summary** at end of session if any tool was skipped

- [ ] **Step 6: Lock setup too** — wrap `runSetup()` in lock.Acquire / lock.Release

- [ ] **Step 7: Verify ALL 22 acceptance tests GREEN** (7 alpha.1 + 7 alpha.2 + 8 alpha.3)

- [ ] **Step 8: Real-binary smoke** — `ca-bootstrap repair --target` against a missing-but-safe tool (e.g., one I don't have)

- [ ] **Step 9: Tutorial chapter 27** — "the repair command: dispatch + verify + journal"

- [ ] **Step 10: Commit**

---

## Task 9 — REFACTOR pass

- [ ] Extract `classify()` from `internal/cli/doctor.go` AND `internal/wizard/steps/prereqs.go` into a shared helper (the duplication flagged in alpha.2's commit)
- [ ] Ensure ASCII fallback covers `repair`'s output as well
- [ ] All tests stay GREEN
- [ ] Tutorial chapter 28 — "REFACTOR: paying down the alpha.2 debt"
- [ ] Commit (one logical refactor per commit)

---

## Task 10 — Open implementation PR (Phase E)

- [ ] Push `feat/alpha-3-impl`
- [ ] Open PR base=`chore/alpha-3-scaffold-and-red` with 12-field metadata
- [ ] Title: `feat(alpha-3): repair --target + session lock — 22/22 acceptance GREEN (AB#<NEW>)`

---

## Self-review

**Spec coverage:**

| Spec § | Covered by |
|---|---|
| §4.1 install/, lock/ packages | Tasks 3-7 |
| §4.2 manifest extension + journal entries | Task 2 + Task 8 |
| §5 repair functional spec | Task 8 |
| §6 session lock | Task 7 |
| §7 journal extensions | Task 8 |
| §8 acceptance tests | Task 1 (RED) + Task 8 (GREEN gate) |

**Placeholder scan:** `AB#<NEW>` markers in commit-message templates — file the alpha.3 PBIs first.

**Type consistency:** `Installer.Install(manifest.Tool, install.Options) install.Result`. `Status` enum. `Lock` interface. All consistent across tasks.

## Execution

Inline execution recommended (live tutorial chapters).
