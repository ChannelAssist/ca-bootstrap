# Building ca-bootstrap (Go) — a TDD walkthrough

> **For onboarding ChannelAssist developers.**
> This document is the **live record** of how `ca-bootstrap` v2.0.0-alpha.1 was built. Every command, every test, every commit you see here is real — you can `git checkout` the corresponding commit and reproduce the state exactly.

## How to use this tutorial

- Read top to bottom on first encounter — chapters build on each other.
- Each chapter corresponds to one task in [`docs/plans/2026-05-25-go-alpha-1-plan.md`](../plans/2026-05-25-go-alpha-1-plan.md).
- Code blocks are exactly what was run. Expected output is shown where it's pedagogically useful.
- Callouts (`> [Why]`, `> [Gotcha]`) explain reasoning future-you might wonder about.

## Prerequisites

- Go 1.23+ (`brew install go` / `winget install GoLang.Go`)
- `git`
- Familiarity with Go modules and the command line. No prior cobra experience needed; this tutorial introduces it.
- Read these first:
  - [`docs/specs/2026-05-25-go-rewrite-pivot.md`](../specs/2026-05-25-go-rewrite-pivot.md) — the **WHY** of the rewrite
  - [`docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`](../specs/2026-05-25-go-v2-0-alpha-1-spec.md) — the **WHAT** of alpha.1

## Background — why TDD here?

Strict TDD (RED → GREEN → REFACTOR) for this rewrite is **non-negotiable**. Three reasons:

1. **Spec-by-example.** The 7 acceptance tests in [spec §9.2](../specs/2026-05-25-go-v2-0-alpha-1-spec.md#92-the-7-mandatory-acceptance-tests-phase-b-deliverable) ARE the alpha.1 contract. If they pass, alpha.1 is done. Tests-first means we lock in *what we want* before we get distracted by *how to build it*.
2. **Bug-class avoidance.** The PowerShell predecessor accumulated a recurring class of stdio/console/encoding bugs (six prior fix commits, including PR #17 that literally dropped the TUI to escape the class — and the symptoms came back anyway). Tests-first force us to *think about edge cases before writing code that has to handle them*. Especially for a tool that probes the user's environment and exits with specific codes.
3. **Confidence to delete.** Every test we write is a license to refactor with confidence later. In a tool that touches a user's environment, knowing the test suite would catch a regression matters more than in most projects.

We use **outside-in TDD**: write all 7 acceptance tests first (one big RED phase), then implement smallest-thing-first to GREEN them one at a time, refactoring between greens. This is a deliberate variant of strict R-G-R-per-test; the spec-by-example framing makes it appropriate here.

## Chapter index

1. [The migration: PS → `legacy/`](#chapter-1--the-migration-ps--legacy)
2. Scaffolding the Go module *(coming next task)*
3. Why fixtures come before tests
4. RED: writing all 7 tests at once
5. GREEN test 1: the smallest possible subcommand
6. GREEN tests 6 & 7: the manifest loader
7. Building the detection interface
8. Probing the host on Unix
9. Probing the host on Windows
10. GREEN remaining tests: the doctor subcommand
11. REFACTOR — making it right after making it work
12. Setting up CI *(deferred — currently disabled per Peter, 2026-05-25)*
13. The release pipeline *(deferred — see Chapter 12)*
14. Shipping — the README rewrite, CHANGELOG, VERSION
15. Tag and release

---

## Chapter 1 — The migration (PS → `legacy/`)

> [Why this is Chapter 1] You can't write Go tests against a Go module that doesn't exist. You can't `go mod init` cleanly in a directory full of PowerShell files (well, you can, but `go vet` and IDE tooling get noisy). And we want `git log --follow` to keep tracing per-file history. So the very first move is: relocate the old code to make room for the new, in a single atomic commit. *This is "Phase C-prep" in the workflow diagram.*

### What we did

```bash
# Branch from current dev so we're working off the most recent state
git checkout dev && git pull --ff-only origin dev
git checkout -b chore/migration-and-scaffold

# Create the destination
mkdir -p legacy legacy/.github

# Move every PS-era file at the root into legacy/
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
git mv GEMINI.md legacy/        # stale: described PS-era code
git mv TEST_PLAN.md legacy/     # historical artifact (v1.1.0 era)

# Disable CI: move workflows to legacy/ so no GH Actions runs trigger
# (overnight directive from Peter — cost-min during the rewrite cycle)
git mv .github/workflows legacy/.github/workflows
```

> [Gotcha] `git mv` (vs `mv` + `git add`) is what tells Git these are renames rather than additions. Without it, `git log --follow legacy/bootstrap.ps1` would only show history from this commit forward — losing every commit that touched the file when it lived at the root.

### What stayed at the repo root

```text
.claude/                # IDE-agent config (Claude Code settings/hooks)
.git/
.github/
  ├── agents/           # Copilot agent definitions
  ├── CODEOWNERS        # branch-protection ownership
  ├── dependabot.yml    # dep updates
  └── pull_request_template.md
.gitignore
CHANGELOG.md
CLAUDE.md               # agent instructions; will get a Go-era refresh later
DESIGN.md
README.md               # gets the Go-era rewrite in Task 14
docs/                   # specs, plans, this tutorial, the collaboration HTML
legacy/                 # ← we just created this
manifest/               # tools.yaml — the Go binary reads it directly via go:embed
```

> [Why .github stays mostly at root] The non-workflow content (`CODEOWNERS`, `dependabot.yml`, `pull_request_template.md`, `agents/`) is policy/config that should keep functioning during the rewrite. Only `workflows/` moves to `legacy/` so GitHub Actions doesn't run on every push — that's the cost-control move.

### What we created in `legacy/`

`legacy/README.md` — a one-page pointer that explains:
- Why this directory exists (link to the pivot doc)
- The archival tag (`legacy/v1.9.0`)
- How to invoke the PS implementation directly if you need to
- That no new features land here

### What this commit looks like

```text
$ git status --short | head -10
R  .github/workflows/ci.yml -> legacy/.github/workflows/ci.yml
R  .github/workflows/release.yml -> legacy/.github/workflows/release.yml
R  GEMINI.md -> legacy/GEMINI.md
R  Makefile -> legacy/Makefile
R  TEST_PLAN.md -> legacy/TEST_PLAN.md
R  bootstrap.ps1 -> legacy/bootstrap.ps1
R  bootstrap.sh -> legacy/bootstrap.sh
R  ca-bootstrap.ps1 -> legacy/ca-bootstrap.ps1
R  commands/doctor.ps1 -> legacy/commands/doctor.ps1
...
A  legacy/README.md
A  docs/tutorials/tdd-walkthrough.md
```

About 80 renames (most of `lib/`, `commands/`, `steps/`, `tests/` recursively) plus the two new files. Single signed commit. Single atomic operation as far as `git log` is concerned.

### The takeaway

The PowerShell implementation is **archived, not deleted**. You can `git checkout legacy/v1.9.0` to see it standalone. You can run it directly via `pwsh legacy/ca-bootstrap.ps1 setup`. We just made room for the new code at the root.

The next chapter scaffolds the Go module on top of this clean root. **No Go file exists yet** — that's deliberate. We'll add the smallest possible scaffold, prove it compiles, then move on.

---

## Chapter 2 — Scaffolding the Go module

> [Why this is Chapter 2, not part of Chapter 1] We could have done the `git mv` and the `go mod init` in the same commit. We deliberately didn't. **Discrete commits = bisectable history.** If something goes sideways at any point in this build, `git bisect` should be able to tell us *exactly* which change broke it. A 95-rename commit is already noisy; mixing in a Go module declaration would make it worse.

### What we did

```bash
go mod init github.com/ChannelAssist/ca-bootstrap
go get github.com/spf13/cobra@latest
go mod tidy
```

That produces:

```text
$ cat go.mod
module github.com/ChannelAssist/ca-bootstrap

go 1.23

require github.com/spf13/cobra v1.10.2

require (
    github.com/inconshreveable/mousetrap v1.1.0 // indirect
    github.com/spf13/pflag v1.0.9 // indirect
)
```

> [Why `go 1.23`] `go mod init` set this to the locally-installed version (we're on 1.26 as of writing). The convention is to declare the **minimum** version, and 1.23 is what the spec promises support for. Manually setting it to 1.23 means a developer on an older 1.23 toolchain can still build the project.

### The two scaffold files

`cmd/ca-bootstrap/main.go` — the entry point. Three responsibilities:

1. Hold the build-time ldflag-injected vars (`Version`, `Commit`, `BuildTime`).
2. Pass them into the `cli` package via `cli.SetBuildInfo`.
3. Invoke `cli.Execute()` and exit 1 if it returns an error.

```go
package main

import (
    "os"
    "github.com/ChannelAssist/ca-bootstrap/internal/cli"
)

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

> [Why `internal/`] Go treats any package under `internal/` as private to the module it belongs to. Nothing outside `github.com/ChannelAssist/ca-bootstrap/...` can import it. This is enforced by the toolchain, not by convention — `go build` will fail if you try. For a CLI that has no library consumers, putting everything except `main` under `internal/` is the canonical pattern.

`internal/cli/root.go` — the cobra root command. Empty (no subcommands yet) but it compiles and renders `--help`:

```go
package cli

import "github.com/spf13/cobra"

var (
    version   = "dev"
    commit    = "unknown"
    buildTime = "unknown"
)

func SetBuildInfo(v, c, t string) {
    version, commit, buildTime = v, c, t
}

var rootCmd = &cobra.Command{
    Use:   "ca-bootstrap",
    Short: "ChannelAssist developer bootstrap",
    Long:  `...`,
}

func Execute() error {
    return rootCmd.Execute()
}
```

> [Why setter instead of exported vars] `main` shouldn't reach into `cli` and mutate package-level state directly. The setter encodes the injection contract: `main` calls `SetBuildInfo(...)` once at startup, and `cli` is free to use those values internally. If we change the storage later (move to a struct, add validation), `main` doesn't notice.

### Confirming it compiles

```bash
$ go build -o /tmp/ca-bootstrap-scaffold-check ./cmd/ca-bootstrap
$ /tmp/ca-bootstrap-scaffold-check --help
ca-bootstrap takes a fresh laptop to a working ChannelAssist
development environment.

v2.0.0-alpha.1 implements:
  ca-bootstrap version    Print version, commit, build time
  ca-bootstrap doctor     Diagnose installed tooling (read-only)

Future alphas add setup (alpha.2), repair (alpha.3), undo (alpha.4),
and self-update (beta.1). See docs/specs/2026-05-25-go-rewrite-pivot.md.
$ rm -f /tmp/ca-bootstrap-scaffold-check
```

> [Why `--help` works without subcommands] Cobra's root command has a default `--help` handler that prints the `Long` description. We get this for free without writing any subcommand. Running the binary with no args also prints help (the root cmd has no `Run` function — cobra defaults to "show help"). Useful sanity check.

### `.gitignore` updates

Added a Go section to `.gitignore`:

```text
# ─── Go (v2.0.0+ rewrite) ──────────────────────────────────────────────
/dist/
/bin/
*.test
*.out
coverage.out
ca-bootstrap                              # local-build binary (root)
ca-bootstrap.exe                          # local-build binary (Windows)
/cmd/ca-bootstrap/ca-bootstrap            # local-build binary (in cmd dir)
/cmd/ca-bootstrap/ca-bootstrap.exe
```

> [Why ignore the binary in two places] `go build ./cmd/ca-bootstrap` (no `-o`) drops the binary in the **current** directory. `go build -o ./bin/ca-bootstrap ./cmd/ca-bootstrap` puts it in `./bin/`. Both are valid local-dev patterns; both should be ignored. Release builds will go in `/dist/`.

### The takeaway

We now have a Go module that compiles and has a cobra root command. **No subcommands. No tests. No production code.** That's deliberate — we add things only when a failing test demands them, starting in Chapter 4.

The next chapter does test fixtures *before* the first test, because tests depend on fixtures, and we want each commit to leave the tree in a state where every file makes sense in isolation.

---

## Chapter 3 — Why fixtures come before tests

> [Why this is its own chapter] Tests reference fixtures. If we wrote the test file first, every test would fail at *file-not-found* before we got to verify anything about the actual behavior. So fixtures land in their own commit. Same bisectability principle as Chapter 2.

### Go's `testdata/` convention

Any directory named `testdata` is special-cased by the Go build system: it's **excluded from package builds** but accessible to tests in the same package. You can put any file in there — YAML, JSON, JPEG, whatever — and it won't be parsed as Go.

We placed fixtures at `tests/acceptance/testdata/`. The 7 acceptance tests in Chapter 4 will reference them via:

```go
filepath.Join(cwd, "testdata", "two-real-tools.yaml")
```

> [Gotcha] `testdata/` only works as a literal directory name. `test_data/` or `fixtures/` don't get the special exclusion. Go's `go test` tooling looks for `testdata/` specifically.

### The 5 fixtures and what they're for

```text
tests/acceptance/testdata/
├── two-real-tools.yaml         → TestDoctor_AllToolsPresent_ExitsZero
├── one-missing-required.yaml   → TestDoctor_RequiredToolMissing_ExitsTwo
├── one-impossibly-new.yaml     → TestDoctor_RequiredToolBelowMin_ExitsTwo
├── one-missing-optional.yaml   → TestDoctor_OptionalToolMissing_ExitsZeroWithWarning
└── malformed.yaml              → TestDoctor_ManifestParseError_ExitsOneToStderr
```

The 7th test (`TestDoctor_ManifestMissing_ExitsOneToStderr`) uses no fixture — it points `$CA_BOOTSTRAP_MANIFEST` at a path that definitely doesn't exist (`/tmp/this-file-does-not-exist-2026.yaml`) and asserts the missing-file error path.

The first test (`TestVersion_PrintsSemverCommitAndBuildTime`) also uses no fixture — `version` doesn't read the manifest.

### Why `go` and `git` for the "real tools" fixture

The "all tools present" test needs to assert exit 0 against tools that *actually exist on every machine running the test*. Two safe bets:

- `go` — we needed it to build the binary under test, so it's definitely on PATH.
- `git` — required by `actions/checkout@v4` and by every developer running this locally.

A bad choice would have been something like `docker` (not on every CI runner) or `node` (not installed on a Go-only dev box). The test would be brittle and flaky.

### Why `xyzzy-nonexistent`

For the "missing required" and "missing optional" tests, we need a tool name that *definitely doesn't exist anywhere*. `xyzzy` is a programmer's-folklore nonword (from the original Adventure text game). No real tool ships with this name. If we'd used something like `cobol-compiler` or `delphi`, we'd risk a false negative on a developer who actually had it installed.

> [Why we care] False negatives in TDD are subtle but corrosive. If a test passes for the wrong reason, you don't notice — until much later when the real implementation breaks behavior the test should have caught.

### Why the deliberately-broken YAML

`malformed.yaml` contains:

```yaml
version: 1
tools:
  - id: "this string never ends
    detect:
      command: anything
```

The unterminated double quote makes yaml.v3 fail at `Unmarshal` with a parse error. We need a test that exercises the **parse-error path** in our manifest loader (spec §7.1, validation rule "manifest parse error → exit 1"). A broken YAML is the simplest way to trigger that branch deterministically.

### The takeaway

Five YAML files; ~50 lines of declarative test setup. No Go code yet. No tests yet. Each fixture has a comment header naming the test it serves — when the next chapter writes the tests, the linkage is unambiguous.

Next: we write the test file. All 7 tests at once. They all fail because no subcommands are wired. That's the RED gate.

---

## Chapter 4 — RED: writing all 7 tests at once

> [The moment of truth] We're about to write code that **deliberately fails to run**. This feels backwards. It isn't. The point of RED is to prove the test *can* fail — that it tests something real. A test that's always green is worse than no test: it gives you false confidence.

### The build tag

The very first line of `acceptance_test.go`:

```go
//go:build acceptance
```

This is a Go **build tag**. Without `-tags acceptance` on the command line, the file is invisible to the compiler. So `go test ./...` (plain) skips this file entirely. `go test -tags acceptance ./tests/acceptance/...` is what runs it.

> [Why a build tag] Each acceptance test builds the whole binary in a temp dir. That's slow (a few hundred ms per test, ~3 seconds total). We don't want every `go test` during dev to pay that cost. Build tag gates it cleanly.

### The `buildBinary` helper

Each test compiles a fresh `ca-bootstrap` into `t.TempDir()`:

```go
func buildBinary(t *testing.T) string {
    tmpDir := t.TempDir()
    binPath := filepath.Join(tmpDir, "ca-bootstrap")  // ".exe" on Windows

    cmd := exec.Command("go", "build",
        "-ldflags", "-X main.Version=2.0.0-test -X main.Commit=testcommit -X main.BuildTime=2026-05-25T00:00:00Z",
        "-o", binPath,
        "./cmd/ca-bootstrap")
    cmd.Dir = repoRoot  // walks ../../ from the test file
    // ...
}
```

> [Why each test rebuilds] At first glance it looks wasteful — wouldn't a `TestMain` that builds once be cheaper? Yes, but it would couple the tests to a shared binary location, and the test would depend on test-execution order. Each test owning its own build in `t.TempDir()` (which Go auto-cleans) means tests are hermetic and parallel-safe. Cost: ~3 extra seconds total. Worth it.

### The `run` helper

```go
func run(t *testing.T, binPath string, manifest string, args ...string) (string, string, int) {
    cmd := exec.Command(binPath, args...)
    if manifest != "" {
        cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST="+manifest)
    } else {
        cmd.Env = append(os.Environ(), "CA_BOOTSTRAP_MANIFEST=/tmp/this-file-does-not-exist-2026-acceptance.yaml")
    }
    // capture stdout, stderr, exit code
}
```

> [Why always set the env var] If `manifest` is empty, we set the env var to a path that definitely doesn't exist. This means tests **never** accidentally pick up the embedded default manifest (which doesn't exist yet anyway, but that changes in Task 6). Hermeticity > convenience.

### The 7 tests in summary

| # | Test | Drives spec § | Expected exit |
|---|---|---|---|
| 1 | `Version_PrintsSemverCommitAndBuildTime` | §5.2 | 0 |
| 2 | `Doctor_AllToolsPresent_ExitsZero` | §6.3 | 0 |
| 3 | `Doctor_RequiredToolMissing_ExitsTwo` | §6.3 | 2 |
| 4 | `Doctor_RequiredToolBelowMin_ExitsTwo` | §6.3 | 2 |
| 5 | `Doctor_OptionalToolMissing_ExitsZeroWithWarning` | §6.3 | 0 |
| 6 | `Doctor_ManifestMissing_ExitsOneToStderr` | §6.4 | 1 (stderr) |
| 7 | `Doctor_ManifestParseError_ExitsOneToStderr` | §6.4 | 1 (stderr) |

### Watching them all fail

```text
$ go test -tags acceptance ./tests/acceptance/...
--- FAIL: TestVersion_PrintsSemverCommitAndBuildTime (0.43s)
--- FAIL: TestDoctor_AllToolsPresent_ExitsZero (0.42s)
--- FAIL: TestDoctor_RequiredToolMissing_ExitsTwo (0.42s)
--- FAIL: TestDoctor_RequiredToolBelowMin_ExitsTwo (0.42s)
--- FAIL: TestDoctor_OptionalToolMissing_ExitsZeroWithWarning (0.43s)
--- FAIL: TestDoctor_ManifestMissing_ExitsOneToStderr (0.45s)
--- FAIL: TestDoctor_ManifestParseError_ExitsOneToStderr (0.42s)
FAIL    github.com/ChannelAssist/ca-bootstrap/tests/acceptance    3.179s
FAIL
```

**7/7 fail. None error.** That's the right kind of red.

### Reading the failure messages

Looking at one:

```text
acceptance_test.go:135: doctor: expected exit 2 (drift), got 0. stdout:
    ca-bootstrap takes a fresh laptop to a working ChannelAssist
    development environment.
    ...
```

The binary built (no `build failed:` error). It ran. It exited 0. And it printed the **root command's `Long` help text** — because `doctor` isn't registered as a subcommand, so cobra falls back to "I don't know that command, here's the help."

That's exactly the diagnostic we want. Every test is failing because **the feature is missing**, not because the test infrastructure is broken.

### The RED Gate is open

This is the explicit checkpoint the spec demands (§9.2): *all 7 tests must exist and fail for the right reason before any non-test code in `internal/` or `cmd/` is committed*.

We're satisfied. Time to start making them pass — one at a time, smallest thing first, refactoring between greens.

### The takeaway

We just wrote 7 tests for code that doesn't exist. We ran them. They failed predictably. That sequence — write test, watch fail, *then* write code — is what separates TDD from "tests as afterthought."

The next chapter implements the easiest one: `version`. ~10 lines of Go. One test goes from RED to GREEN. The other 6 stay RED. That's the correct intermediate state.

---

## Chapter 5 — GREEN test 1: the smallest possible subcommand

> [The first green] We have 7 failing tests. The discipline is: pick the easiest one, write the **smallest** code that makes it pass, and don't do anything else. No "while I'm here." No "let me also fix...". The `version` subcommand is ~10 lines; that's all we add.

### The code

`internal/cli/version.go`:

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

That's it. 17 lines including the imports and the blank line. Cobra subcommand pattern in its barest form.

> [Why `init()` registration] Cobra subcommands are commonly registered via `func init() { rootCmd.AddCommand(...) }` in their own files. The pattern means **adding a new subcommand is a single-file change**. We don't have to modify `root.go` every time. Each subcommand is self-contained — own file, own `init()`, own registration. Scales well as we add `doctor`, eventually `setup`, `repair`, etc.

> [Why `RunE` instead of `Run`] `Run` is `func(*cobra.Command, []string)` — no return value. `RunE` is `func(*cobra.Command, []string) error`. Using `RunE` even when we don't currently return an error is forward-looking: if later we need to fail out of `version` (file unreadable, ldflag corrupt, anything), the signature already supports it. Cobra handles a non-nil error by printing it to stderr and exiting 1.

> [Why `fmt.Printf` not `cmd.Println`] Either works. For `version` we want output on the actual program stdout (a user piping to `grep` should see it). `fmt.Printf` is the stdlib default and writes to `os.Stdout`. Cobra's `cmd.Println` writes to the same place by default but adds a layer of indirection we don't need yet.

### Running it

```bash
$ go build -o /tmp/cab ./cmd/ca-bootstrap
$ /tmp/cab version
ca-bootstrap dev (commit unknown, built unknown)
```

`dev / unknown / unknown` because we didn't pass any ldflags locally. The acceptance test sets them:

```text
-ldflags "-X main.Version=2.0.0-test -X main.Commit=testcommit -X main.BuildTime=2026-05-25T00:00:00Z"
```

And asserts the output contains `2.0.0-test`, `testcommit`, and matches the regex `^ca-bootstrap (\S+) \(commit (\S+), built (\S+)\)$`. Both checks pass.

### Verifying the green

```text
$ go test -tags acceptance -run TestVersion ./tests/acceptance/...
ok      github.com/ChannelAssist/ca-bootstrap/tests/acceptance    0.766s
```

Then we run **the whole acceptance suite** to confirm we didn't break anything (we didn't — version was a pure addition):

```text
$ go test -tags acceptance ./tests/acceptance/...
--- PASS: TestVersion_PrintsSemverCommitAndBuildTime  (0.43s)
--- FAIL: TestDoctor_AllToolsPresent_ExitsZero        (0.43s)
--- FAIL: TestDoctor_RequiredToolMissing_ExitsTwo     (0.44s)
--- FAIL: TestDoctor_RequiredToolBelowMin_ExitsTwo    (0.44s)
--- FAIL: TestDoctor_OptionalToolMissing_ExitsZero…   (0.43s)
--- FAIL: TestDoctor_ManifestMissing_ExitsOneToStderr (0.43s)
--- FAIL: TestDoctor_ManifestParseError_ExitsOneToS…  (0.43s)
```

**1 PASS, 6 FAIL.** That's exactly the intermediate state TDD predicts. We never had to look at the test code to make it pass — the spec drove the implementation.

### A note on `version` design choices we *didn't* make

- No `--json` output flag. Spec §5 says alpha.1 doesn't have one.
- No `--short` variant. Same reason.
- No coloring. No emoji. Plain text.

> [Why restraint matters here] Every flag you ship is a flag you maintain. Every flag you don't ship is a flag a future spec gets to design correctly. If someone later actually needs `version --json`, they'll add it then — and they'll add tests for it then. That's how YAGNI compounds positively.

### The takeaway

One test green. Code that does exactly what the test demands and nothing more. The next chapter tackles two tests at once (the two manifest-error tests) by building the loader — these don't need `doctor` to exist yet because they exercise the manifest **path** (missing file, parse error), which doctor will plug into in Task 10.

---

## Chapter 6 — GREEN tests 6 & 7: the manifest loader

> [Tests first, even at this layer] Acceptance tests 6 and 7 (manifest-missing, manifest-parse-error) won't actually go green until the `doctor` subcommand exists in Chapter 10 — they test the *whole-binary* flow. But the manifest **loader** itself is its own unit-testable piece, and TDD discipline says: write unit tests for the loader before writing the loader.

### The schema mismatch we discovered

The plan assumed the existing `manifest/tools.yaml` could be embedded as-is. **It can't**, for two reasons.

**Reason 1: Go's `//go:embed` cannot traverse `..`.** From [the Go docs](https://pkg.go.dev/embed): *"Patterns may not contain '.' or '..' or empty path elements"*. The loader lives at `internal/manifest/manifest.go`; the manifest was at `manifest/tools.yaml`. There's no `//go:embed ../../manifest/tools.yaml` form that works.

So we moved it: `git mv manifest/tools.yaml internal/manifest/tools.yaml` (plus the three other manifest files, for consistency). The spec doc got amended in the same PR per the standing rule that spec + HTML + plan stay in sync.

**Reason 2: the schemas didn't match.** The PowerShell-era file used:

```yaml
required:                   # required and optional were separate lists
  - id: git
    check:                  # not `detect:`
      cmd: "git --version"  # full command string, not separate command+flag
      version_regex: "..."
      min_version: "2.40.0" # nested under check, not top-level
optional:
  - id: docker
    ...
```

The Go-era schema (spec §7) is:

```yaml
tools:                      # one flat list
  - id: git
    optional: false         # boolean per tool
    min_version: "2.40.0"   # top-level field
    detect:                 # not `check:`
      command: git          # separated from version_flag
      version_flag: --version
      version_regex: "..."
```

We migrated the 16-tool inventory by hand (the migration commit is one of the longer changes in this PR). All `required:` items became `optional: false` entries in `tools:`; all `optional:` items became `optional: true`. The `check.cmd: "git --version"` form was split into `detect.command: git` + `detect.version_flag: --version`.

> [Why we didn't make the loader speak both schemas] Two reasons: (a) the spec docs say one schema, and the file should match its spec — drift between "what the docs say" and "what the file does" is exactly the bug class we're trying to escape; (b) the PS-era manifest lives forever at `legacy/v1.9.0` for archaeology, so nothing's lost.

### The loader code

`internal/manifest/manifest.go` is ~110 lines. The key parts:

**Embedded default:**

```go
//go:embed tools.yaml
var embeddedManifest []byte

func LoadDefault() (*Manifest, error) {
    if override := os.Getenv("CA_BOOTSTRAP_MANIFEST"); override != "" {
        return Load(override)
    }
    return parseAndValidate(embeddedManifest, "<embedded>")
}
```

> [The contract] At runtime the binary always has a manifest. The default is what was embedded at build time. `CA_BOOTSTRAP_MANIFEST` overrides for tests, custom manifests, or local experimentation. Spec §6.5 makes this the canonical resolution order: env var > embedded.

**Reading from a path:**

```go
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
```

> [Why a sentinel error] `ErrNotFound = errors.New("manifest not found")` lets callers do `errors.Is(err, ErrNotFound)` to distinguish missing-file from parse-error. The acceptance test `TestDoctor_ManifestMissing_ExitsOneToStderr` will lean on this distinction later — missing file is a different category of error than malformed YAML.

**Validation (the 6 rules from spec §7.1):**

```go
if m.Version == 0 { ... "missing required 'version' field" }
if m.Version != 1 { ... "unsupported manifest version" }
if len(m.Tools) == 0 { ... "missing required 'tools' list" }
for i, t := range m.Tools {
    if t.ID == "" { ... "missing required 'id'" }
    if seen[t.ID] { ... "duplicate tool id" }
    if t.MinVersion != "" && !semverRegex.MatchString(t.MinVersion) { ... "invalid min_version" }
    if t.Detect.Command == "" { ... "missing required detect.command" }
}
```

Each rule has its own fixture (`testdata/missing-version.yaml`, `tool-missing-id.yaml`, etc.) and its own table-driven test case in `TestLoad_ValidationErrors`. One rule = one bug we can write a regression test for later if it ever resurfaces.

### A gotcha we hit: the semver regex was too strict

First iteration of `semverRegex` was `^\d+\.\d+\.\d+(?:[-+][\w.]+)?$` — required `MAJOR.MINOR.PATCH`. The embedded manifest has GNU Make at `min_version: "3.81"` (two-part).

The test `TestLoadDefault_UsesEmbeddedWhenNoEnvVar` caught it:

```text
manifest_test.go:66: LoadDefault from embedded: tool make: invalid min_version "3.81"
```

**The fix was one regex tweak:** make the third `.\d+` group optional. Two-part semver is common (jq is `1.6`, make is `3.81`, sometimes Python ships `3.12` without patch). We accept both.

```go
// Before:
var semverRegex = regexp.MustCompile(`^\d+\.\d+\.\d+(?:[-+][\w.]+)?$`)
// After:
var semverRegex = regexp.MustCompile(`^\d+\.\d+(?:\.\d+)?(?:[-+][\w.]+)?$`)
```

> [Why this is a TDD win] We didn't pre-write the regex correctly. We didn't have to. The test failed at "validate embedded manifest" with a clear message; one regex edit fixed it; all tests green again. Five minutes total. Without the test, we might have shipped a binary that refused to load its own embedded manifest.

### Verifying state

```text
$ go test ./internal/manifest/...
ok  github.com/ChannelAssist/ca-bootstrap/internal/manifest    0.227s

$ go test -tags acceptance ./tests/acceptance/...
--- PASS: TestVersion_PrintsSemverCommitAndBuildTime
--- FAIL: TestDoctor_AllToolsPresent_ExitsZero
--- FAIL: TestDoctor_RequiredToolMissing_ExitsTwo
--- FAIL: TestDoctor_RequiredToolBelowMin_ExitsTwo
--- FAIL: TestDoctor_OptionalToolMissing_ExitsZeroWithWarning
--- FAIL: TestDoctor_ManifestMissing_ExitsOneToStderr
--- FAIL: TestDoctor_ManifestParseError_ExitsOneToStderr
```

Unit tests all green. Acceptance state still 1 PASS / 6 FAIL — doctor isn't wired yet, so the loader's contributions don't surface end-to-end.

### The takeaway

The loader is done. It compiles. Its unit tests pass. The embedded manifest is real (16 tools, valid against the schema). Two acceptance tests (6, 7) will go green automatically once doctor lands in Chapter 10 and *uses* this loader — because the loader's error paths already match what those tests assert.

The next chapter builds the detection layer: the thing that takes a `Tool` struct and answers "is it installed, and at what version?"

---

## Chapter 7 — Building the detection interface

> [Separation of concerns] The detection layer has two parts: **pure logic** (regex matching, semver comparison — doesn't touch the OS) and **OS-touching code** (`exec.LookPath`, `exec.Command`). We separate them deliberately. Pure functions get table-driven unit tests with no fixtures. OS-touching code is harder to test (Chapter 8) — but only the smallest possible part of the system depends on it.

### Three files

```text
internal/detect/
├── detect.go              # Detector interface + Result type (NO OS code)
├── version_parse.go       # ExtractVersion + VersionAtLeast (pure)
├── version_parse_test.go  # 9-row + 6-row table tests for both
├── detect_unix.go         # (next chapter)
└── detect_windows.go      # (chapter after)
```

### The interface

```go
type Detector interface {
    Probe(t manifest.Tool) Result
}

type Result struct {
    ID         string
    Found      bool
    Version    string  // semver-ish; "" if Found=false
    VersionRaw string  // raw output, for debugging
    Err        error   // non-nil iff the probe failed unexpectedly
}
```

Three states a probe can land in:

| State | `Found` | `Version` | `Err` | Meaning |
|---|---|---|---|---|
| Not on PATH | `false` | `""` | `nil` | Clean signal: tool absent. Not an error. |
| Present, parsed | `true` | `"1.2.3"` | `nil` | Happy path. |
| Probe crashed | `?` | `?` | non-nil | Binary errored unexpectedly (very rare). |

> [The "missing tool is not an error" choice] An absent tool is information, not failure. The CLI doesn't have a way to know *up front* whether `xyzzy` should exist — the manifest says "look for xyzzy"; the answer "no" is a fact. Returning an error here would force every probe-site to handle a "well-actually" path. Cleaner to encode "absent" as `Found=false, Err=nil`.

### The pure functions

`ExtractVersion(raw, regex string) string`:

```go
func ExtractVersion(raw, pattern string) string {
    if pattern == "" {
        pattern = defaultVersionRegex  // (\d+\.\d+(?:\.\d+)?)
    }
    re, err := regexp.Compile(pattern)
    if err != nil {
        return ""  // bad regex → empty string, not crash
    }
    match := re.FindStringSubmatch(raw)
    if len(match) < 2 {
        return ""
    }
    return strings.TrimSpace(match[1])
}
```

> [Returning "" not error] If the version can't be parsed, callers treat it as "found but unknown version" — same display as a winget-fallback hit on Windows. Returning an error here would conflate "binary missing" with "parse failed," both of which the user can act on differently.

`VersionAtLeast(got, min string) (bool, error)`:

```go
func VersionAtLeast(got, min string) (bool, error) {
    if min == "" {
        return true, nil  // no min = any version OK
    }
    g, err := parseTriplet(got)  // splits "1.21.5" → [1, 21, 5]
    if err != nil { return false, ... }
    m, err := parseTriplet(min)
    if err != nil { return false, ... }
    for i := 0; i < 3; i++ {
        if g[i] != m[i] { return g[i] > m[i], nil }
    }
    return true, nil  // all three equal
}
```

> [Why a [3]int triplet] Standard semver libraries are 1000s of LOC because they handle prerelease ordering, build metadata, range constraints, etc. We need *one* comparison: "is got at least min?" with both formatted as MAJOR.MINOR.PATCH. A fixed array compared component-by-component is 15 lines and zero external deps. YAGNI in action.

> [How 2-part versions are handled] `parseTriplet("3.81")` returns `[3, 81, 0]` (missing parts default to 0). So `VersionAtLeast("3.81", "3.80.5")` correctly returns `true`. Same logic the manifest validator's relaxed regex enables.

### The 15-row test suite

`TestVersionAtLeast` runs 9 cases covering all the comparison branches plus the empty-min special case. `TestExtractVersion` runs 6 cases including the "bad regex returns empty" and "no match returns empty" branches:

```text
=== RUN   TestVersionAtLeast
    --- PASS: TestVersionAtLeast/equal
    --- PASS: TestVersionAtLeast/got_higher_patch
    --- PASS: TestVersionAtLeast/got_lower_patch
    --- PASS: TestVersionAtLeast/got_higher_major
    --- PASS: TestVersionAtLeast/got_two-part_vs_three-part_min
    --- PASS: TestVersionAtLeast/three-part_got_vs_two-part_min
    --- PASS: TestVersionAtLeast/two-part_below_two-part
    --- PASS: TestVersionAtLeast/prerelease_accepted
    --- PASS: TestVersionAtLeast/empty_min_always_true
=== RUN   TestExtractVersion
    --- PASS: TestExtractVersion/go
    --- PASS: TestExtractVersion/git
    --- PASS: TestExtractVersion/make_2-part
    --- PASS: TestExtractVersion/default_regex
    --- PASS: TestExtractVersion/no_match_returns_empty
    --- PASS: TestExtractVersion/invalid_regex_returns_empty
```

Table-driven tests are idiomatic Go: one `func Test...` runs N subtests via `t.Run(name, func)`. Each row is data — adding a new case is one line. When a future bug surfaces ("our regex broke on Java 17 output"), you add the failing row, watch it red, fix the function, watch it green.

### The compile-error we hit (and a small refactor)

First attempt put `Default() Detector { return defaultDetector{} }` in `detect.go`. The compiler complained:

```text
internal/detect/detect.go:31:9: cannot use defaultDetector{} as Detector value:
    defaultDetector does not implement Detector (missing method Probe)
```

Right — `Probe` is platform-specific. It lives in `detect_unix.go` / `detect_windows.go`, which we haven't written yet. The compiler can't see a `Probe` method on `defaultDetector` because none exists in the current source set.

**Fix:** keep `defaultDetector{}` and `Default()` out of `detect.go`. They'll live in the platform files (one definition per file, build-tag selected). `detect.go` is the *interface* and the *value type*. Implementations bring the receiver type with them.

> [Tutorial-worthy because it's TDD-shaped] A real implementation would have written the function and added a stub Probe and shipped. With TDD pressure, the failure was immediate and the fix structural: own the platform polymorphism in the platform files. Cleaner architecture as a side effect of strict ordering.

### Verifying state

```text
$ go test ./internal/detect/...
ok  github.com/ChannelAssist/ca-bootstrap/internal/detect    0.323s
$ go test ./...
ok  github.com/ChannelAssist/ca-bootstrap/internal/detect
ok  github.com/ChannelAssist/ca-bootstrap/internal/manifest
```

All pure-logic tests green. The interface compiles. Acceptance state unchanged at 1/7 — the detection layer can't do anything end-to-end without a platform implementation and a `doctor` subcommand. Both land in the next chapters.

---

## Chapter 8 — Probing the host on Unix

> [Two-step detection] On Unix-likes (macOS + Linux), tool detection is two operations: **(1) is the binary on PATH?** via `exec.LookPath`, then **(2) what version does it report?** via `exec.Command` + regex. Both stdlib. No external deps.

### The test we wrote first

`detect_unix_test.go` lives under `//go:build darwin || linux` so it's only compiled on those platforms. Three tests:

```go
TestProbe_GoBinary           // happy path: known-present tool
TestProbe_MissingBinary      // not on PATH → Found=false, Err=nil
TestProbe_MultiArgVersionFlag // "env GOOS" splits into 2 args
```

> [Why test against real tools] Some test suites mock `exec.Command` to avoid touching the OS. We don't — we use `go`, which we know is present (we're running `go test` to invoke this test in the first place). Real-binary probes catch real bugs the mocks would miss (PATH lookups behaving differently, version output formats drifting in major releases, etc.).

### The implementation

```go
//go:build darwin || linux

type unixDetector struct{}

func Default() Detector {
    return unixDetector{}
}

func (unixDetector) Probe(t manifest.Tool) Result {
    r := Result{ID: t.ID}

    if _, err := exec.LookPath(t.Detect.Command); err != nil {
        return r  // Not on PATH — Found stays false, no error.
    }

    versionFlag := t.Detect.VersionFlag
    if versionFlag == "" {
        versionFlag = "--version"  // sensible default
    }
    args := strings.Fields(versionFlag)  // whitespace-split

    cmd := exec.Command(t.Detect.Command, args...)
    out, err := cmd.CombinedOutput()
    if err != nil {
        var exitErr *exec.ExitError
        if !errors.As(err, &exitErr) {
            r.Err = err  // process couldn't start at all
            return r
        }
        // Non-zero exit is OK — fall through with whatever we got.
    }
    r.Found = true
    r.VersionRaw = strings.TrimSpace(string(out))
    r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
    return r
}
```

> [Why `strings.Fields`] The manifest's `version_flag` is a single string, but some tools need multiple flags: `kubectl version --client`, `helm version --short`, `go env GOOS`. We split on whitespace so the manifest stays readable while the implementation supports multi-arg flags transparently. `strings.Fields` (not `strings.Split`) handles any-whitespace and skips empty tokens.

> [Why `CombinedOutput` not `Output`] Some tools print their version to stderr (notably old gcc, some Java versions). `CombinedOutput` captures both stdout AND stderr. The regex doesn't care which stream it came from.

> [Why we tolerate non-zero exits] `git --version` exits 0. But `node --version` historically returns 0; `claude --version` might exit 1 with the version on stderr; some tools exit 64 (EX_USAGE) when they think `--version` is unknown but they still printed something useful. We tolerate non-zero as long as the process *started*. We fail only if the process couldn't start — that's a real OS-level error (binary corrupt, permissions issue).

### The shape of a `Result`

For each probe, one of four outcomes:

| Scenario | Found | Version | VersionRaw | Err |
|---|---|---|---|---|
| Binary not on PATH | false | "" | "" | nil |
| Found + version parsed | true | "1.21.5" | "go version go1.21.5 darwin/arm64" | nil |
| Found + regex didn't match | true | "" | full output | nil |
| Process couldn't start | false | "" | "" | non-nil |

The `Found=true + Version=""` case is interesting — it means "the tool exists but we can't tell which version." Downstream display logic (in `doctor`) handles it as "present, version unknown" — neither drift nor confirmed-OK. We've encoded ambiguity in the type.

### Verifying

```text
$ go test ./internal/detect/...
--- PASS: TestProbe_GoBinary
--- PASS: TestProbe_MissingBinary
--- PASS: TestProbe_MultiArgVersionFlag
... (plus 15 existing pure-function tests)
ok  github.com/ChannelAssist/ca-bootstrap/internal/detect    0.291s
```

Acceptance state: still 1/7. The detection layer works; doctor still doesn't exist.

### Windows is next

The Windows implementation needs everything the Unix one has, plus a fallback for tools installed by winget that don't end up on PATH (Microsoft Store apps, Electron GUIs). That's Chapter 9.

---

## Chapter 9 — Probing the host on Windows

> [Why Windows needs more] On Unix, "is this tool installed" is essentially synonymous with "is its binary on PATH." Windows breaks that assumption — Microsoft Store apps, MSI installers, and Electron GUIs frequently install to `%LOCALAPPDATA%` or `Program Files\WindowsApps\` without touching the PATH. A tool can be very much "installed" and still fail `exec.LookPath`. So our Windows probe needs a fallback.

### Two-stage detection

```text
1. exec.LookPath(command)         → on PATH?    yes → run --version → done
2. winget list --id <command>     → installed?  yes → return Found=true, Version=""
3. (neither)                                          → Found=false
```

```go
//go:build windows

func (windowsDetector) Probe(t manifest.Tool) Result {
    r := Result{ID: t.ID}

    // Primary: PATH lookup
    if path, err := exec.LookPath(t.Detect.Command); err == nil {
        return runVersionAt(t, r, path)
    }

    // Fallback: winget list
    if wingetAvailable() && wingetHasPackage(t.Detect.Command) {
        r.Found = true
        r.VersionRaw = "winget: present (not on PATH)"
        return r
    }
    return r
}
```

`runVersionAt` does the same exec-and-parse as Unix; `wingetAvailable` and `wingetHasPackage` are small helpers.

### The "Found but Version unknown" path

When we hit the winget fallback, we know the tool is installed but we *can't* run it via `exec.Command` (it's not on PATH). So `Version` stays empty. Downstream:

- `doctor`'s output will show the tool with "present, version unknown" rather than a ✓ with a version. We don't have enough info to decide "OK vs drift" against `min_version`, so we display it as "found, requires manual verification."

For alpha.1 we tolerate this gracefully without doing extra work. alpha.2+ may add `paths:` declarations in the manifest (PS era had these — see `legacy/internal/manifest/tools.yaml` for the `claude-desktop` entry with `paths.windows: [...]`) to enable PATH-bypassing version probes via parsing `Get-AppPackage` or similar.

### Verifying without a Windows host

We're on macOS. We can't run the Windows tests directly. But Go's cross-compile lets us verify the code is *correct enough to compile* on a Windows target:

```text
$ GOOS=windows go vet ./...
# (no output, exit 0)

$ GOOS=windows GOARCH=amd64 go build -o /tmp/cab-check.exe ./cmd/ca-bootstrap
# (exit 0)
```

`go vet` runs the full static-analysis suite (unreachable code, shadowed variables, suspicious type assertions, etc.) against the Windows view of the source — including `detect_windows.go` while `detect_unix.go` is invisible due to build tags. Catches typos and most refactor mistakes.

Real Windows acceptance test runs land in the release pipeline (`release.yml` matrix builds + runs on `windows-latest`). For tonight, we have static analysis confidence; ship it.

> [What we can't catch cross-platform] What we *can't* verify on macOS:
> - `winget list` actually returning the expected text (their output format might drift)
> - PATH semantics on Windows (`%PATH%` vs case-insensitive lookup)
> - The "Microsoft protected your PC" SmartScreen flow at first run
>
> Those are deferred to the Windows smoke test in the eventual release PR.

### Acceptance state

Still 1/7. Both platform probes exist, but no `doctor` subcommand to invoke them. That's the entire content of Chapter 10 — the climactic chapter where the 6 remaining tests go GREEN at once.

---

## Chapter 10 — GREEN remaining tests: the doctor subcommand

> [The climax] We have 1 test green and 6 red. Everything we've written so far is plumbing — manifests, detectors, semver compare. None of it has been wired together. This chapter wires it. When we're done, all 7 tests turn green at once. That's because we built the right plumbing in the right order — driven by the test suite, not by hunches.

### One subcommand. Two test files. Six tests turning green.

The doctor subcommand is **two files**:

`internal/cli/doctor.go` (~100 LOC): the cobra command + the `runDoctor` function.
`internal/cli/doctor_test.go` (~70 LOC): four integration tests with a stub Detector.

### Test first — the integration tests

```go
type stubDetector struct {
    results map[string]detect.Result
}

func (s stubDetector) Probe(t manifest.Tool) detect.Result {
    if r, ok := s.results[t.ID]; ok {
        r.ID = t.ID
        return r
    }
    return detect.Result{ID: t.ID, Found: false}
}
```

A canned-results Detector. Lets us test `runDoctor` end-to-end *without* actually probing the host. The 4 tests cover:

| Test | Setup | Asserts |
|---|---|---|
| `TestRunDoctor_ClassifiesResults` | mix of ok / drift / missing-required / missing-optional | exit 2, all 4 status lines present, summary counts correct |
| `TestRunDoctor_AllOK_ExitsZero` | one tool, present, at version | exit 0 |
| `TestRunDoctor_OnlyOptionalMissing_ExitsZero` | required-present + optional-absent | exit 0 (optional missing ≠ drift) |
| `TestRunDoctor_BelowMinForOptional_DoesNotDrift` | optional present but below min | exit 0 (optional below-min surfaces as ⚠, not ✗) |

> [Why integration tests in addition to acceptance tests] The acceptance tests build a real binary. They're slow (~3s total) and they break loudly when the world changes (PATH semantics, OS versions). The integration tests in `cli/doctor_test.go` use a stub Detector — they run in 0.3ms each and exercise EVERY code path in `runDoctor` deterministically. **Two tiers of tests catch different bug classes.**

### The implementation

```go
func runDoctor(w io.Writer, m *manifest.Manifest, d detect.Detector) int {
    fmt.Fprintln(w, "Checking installed tooling against manifest/tools.yaml...")
    fmt.Fprintln(w)

    var ok, drift, missingOpt int
    for _, tool := range m.Tools {
        r := d.Probe(tool)
        switch classify(tool, r) {
        case classOK:
            fmt.Fprintf(w, "  ✓ %s\t%s  (manifest min: %s)\n", tool.ID, r.Version, tool.MinVersion)
            ok++
        case classDrift:
            fmt.Fprintf(w, "  ✗ %s\t%s  (manifest min: %s)   → install %s\n",
                tool.ID, displayVersion(r), tool.MinVersion, tool.ID)
            drift++
        case classMissingOptional:
            fmt.Fprintf(w, "  ⚠ %s\tnot found                       → optional\n", tool.ID)
            missingOpt++
        }
    }
    fmt.Fprintf(w, "\n%d tools checked: %d ok, %d drift, %d missing-optional\n",
        len(m.Tools), ok, drift, missingOpt)
    if drift > 0 {
        return 2
    }
    return 0
}
```

> [Why `runDoctor` takes `io.Writer` and `Detector`] So tests can inject `bytes.Buffer` and `stubDetector`. The cobra `RunE` callback wires real `os.Stdout` + `detect.Default()`. Same function, two callers, only one of which touches the OS. This is dependency-injection without the framework: just take an interface.

### The classification helper

```go
type classification int
const (classOK classification = iota; classDrift; classMissingOptional)

func classify(t manifest.Tool, r detect.Result) classification {
    if !r.Found {
        if t.Optional { return classMissingOptional }
        return classDrift
    }
    if t.MinVersion != "" {
        ok, err := detect.VersionAtLeast(r.Version, t.MinVersion)
        if err != nil || !ok {
            if t.Optional { return classMissingOptional }
            return classDrift
        }
    }
    return classOK
}
```

Three cases, four branches each. Encapsulated in 15 lines. Each branch has a corresponding test row. **Small enums + exhaustive switches are testable and obvious; if/else chains rot.**

### The moment of truth

```text
$ go test -tags acceptance ./tests/acceptance/... -v
=== RUN   TestVersion_PrintsSemverCommitAndBuildTime
--- PASS
=== RUN   TestDoctor_AllToolsPresent_ExitsZero
--- PASS
=== RUN   TestDoctor_RequiredToolMissing_ExitsTwo
--- PASS
=== RUN   TestDoctor_RequiredToolBelowMin_ExitsTwo
--- PASS
=== RUN   TestDoctor_OptionalToolMissing_ExitsZeroWithWarning
--- PASS
=== RUN   TestDoctor_ManifestMissing_ExitsOneToStderr
--- PASS
=== RUN   TestDoctor_ManifestParseError_ExitsOneToStderr
--- PASS
PASS
ok  github.com/ChannelAssist/ca-bootstrap/tests/acceptance    3.339s
```

**7/7 GREEN.** The 6 doctor tests turned green simultaneously — because we built `runDoctor` to match `classify`'s expected behavior, `classify` to match the spec's exit-code table, the spec to match the acceptance tests. Tests led; implementation followed.

### The real smoke run

Built locally and ran against the real manifest:

```text
$ go build -o /tmp/cab ./cmd/ca-bootstrap
$ /tmp/cab version
ca-bootstrap dev (commit unknown, built unknown)

$ /tmp/cab doctor
Checking installed tooling against manifest/tools.yaml...

  ✓ git           2.54.0   (manifest min: 2.40.0)
  ✓ gh            2.92.0   (manifest min: 2.30.0)
  ✓ pwsh          7.6.1    (manifest min: 7.0.0)
  ✓ make          3.81     (manifest min: 3.81)
  ✓ dotnet-10     10.0.107
  ✓ az            2.86.0   (manifest min: 2.60.0)
  ✓ kubectl       1.34.1   (manifest min: 1.28.0)
  ✓ helm          4.2.0    (manifest min: 3.10.0)
  ✓ jq            1.8      (manifest min: 1.6)
  ✓ psql          18.4     (manifest min: 14.0)
  ✓ node-20       22.22.2  (manifest min: 20.0.0)
  ✓ python-312    3.14.5   (manifest min: 3.12.0)
  ✓ docker        29.5.2
  ✓ vscode        1.120.0
  ✓ claude-code   2.1.150
  ✓ copilot-cli   1.0.51

16 tools checked: 16 ok, 0 drift, 0 missing-optional

$ echo $?
0
```

**16 tools detected. Zero drift. Exit 0.** The whole thing — detection, version regex, semver compare, classification, formatting — works against a real machine on the first try because every layer was tested in isolation before being wired together.

### The takeaway

We've achieved alpha.1's functional surface: `version` + `doctor`. 7 acceptance tests green. Unit + integration tests green. Real-binary smoke run green. The next chapter (REFACTOR) is the cleanup pass — extract duplication, add the ASCII fallback, no new behavior, all tests stay green.

After that we open the implementation PR (Phase E in the workflow diagram) and stop per Peter's overnight directive. Tasks 12-13 (CI + release pipelines) are deferred until CI is re-enabled.

---

## Chapter 11 — REFACTOR — making it right after making it work

> [The discipline of NOT changing behavior] REFACTOR is the R in Red-Green-Refactor. Its rule is simple: **the test suite is the contract; the refactor must not change which tests pass**. We're allowed to clean up code; we're not allowed to alter externally observable behavior. The green test suite is the safety net.

### What we noticed during implementation

After Tasks 8 and 9 we had **duplicated logic** in `detect_unix.go` and `detect_windows.go`:

```go
// Both files had something like:
versionFlag := t.Detect.VersionFlag
if versionFlag == "" { versionFlag = "--version" }
args := strings.Fields(versionFlag)
cmd := exec.Command(path, args...)
out, err := cmd.CombinedOutput()
if err != nil {
    var exitErr *exec.ExitError
    if !errors.As(err, &exitErr) { r.Err = err; return r }
}
r.Found = true
r.VersionRaw = strings.TrimSpace(string(out))
r.Version = ExtractVersion(r.VersionRaw, t.Detect.VersionRegex)
```

That's 10 lines, identical, in two files. Duplication is debt that gets paid by every future refactor. Extract.

### The extraction

Move the shared block into `detect.go` (the build-tag-free file) as `runVersionProbe(path string, t manifest.Tool) Result`:

```go
// detect.go (shared)
func runVersionProbe(path string, t manifest.Tool) Result {
    r := Result{ID: t.ID}
    // ... the 10 lines that used to live in both files ...
    return r
}
```

Then `detect_unix.go` shrinks to:

```go
func (unixDetector) Probe(t manifest.Tool) Result {
    path, err := exec.LookPath(t.Detect.Command)
    if err != nil { return Result{ID: t.ID} }
    return runVersionProbe(path, t)
}
```

And `detect_windows.go`:

```go
func (windowsDetector) Probe(t manifest.Tool) Result {
    if path, err := exec.LookPath(t.Detect.Command); err == nil {
        return runVersionProbe(path, t)
    }
    if wingetAvailable() && wingetHasPackage(t.Detect.Command) {
        return Result{ID: t.ID, Found: true, VersionRaw: "winget: present (not on PATH)"}
    }
    return Result{ID: t.ID}
}
```

Each platform Probe is now 3 lines (Unix) or 7 lines (Windows). The dispatch story is obvious from the structure: PATH lookup, then a per-platform fallback (Windows has winget; Unix doesn't).

### Verifying behavior didn't change

```text
$ go test ./...                            # all PASS
$ go test -tags acceptance ./tests/...     # 7/7 PASS
$ GOOS=windows go vet ./...                # exit 0
```

Zero new test cases, zero changed test expectations — the refactor moved code without changing what the system does.

### The ASCII glyph fallback

Spec §6.2 calls out a `CA_BOOTSTRAP_ASCII` env var that swaps `✓`/`✗`/`⚠` for `[ok]`/`[FAIL]`/`[warn]`. We deferred this from Task 10 — it has no acceptance test (the spec didn't require one), so it's strictly a quality-of-life enhancement.

Added to `doctor.go`:

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

Then the format strings change from `"  ✓ %s..."` to `"  %s %s..."` with `glyphOK` as the first arg.

> [Why this is REFACTOR-shaped, not feature-shaped] It changes a single rendering detail (glyphs) without changing classification logic, exit codes, or output structure. The acceptance tests still assert on the UTF-8 glyphs because that's the default; they don't care about the ASCII path. We could add an acceptance test for `CA_BOOTSTRAP_ASCII=1`, but spec didn't require one, and alpha.2 has bigger concerns.

> [Smoke-verifying the fallback]
> ```text
> $ CA_BOOTSTRAP_ASCII=1 /tmp/cab doctor
> Checking installed tooling against manifest/tools.yaml...
>
>   [ok] git    2.54.0  (manifest min: 2.40.0)
>   [ok] gh     2.92.0  (manifest min: 2.30.0)
>   ...
> ```

### What we deliberately didn't refactor

- **The 8 manifest validation rules in `parseAndValidate`.** They're a flat sequence of guards; extracting helpers would obfuscate the order. Sometimes a long function is the right answer.
- **The `runDoctor` function's switch statement.** Three cases, three branches. Extracting per-case helpers would scatter the loop body across the file.
- **The glyph const naming.** `glyphOK` / `glyphFail` / `glyphWarn` are mutable package-level vars (so `init()` can swap them based on env). Some teams prefer immutability + `func glyph(c classification) string`. The mutable-with-init pattern is small and obvious for one feature; we'd revisit if more output styling lands.

### The takeaway

The implementation surface is **stable**: 7/7 acceptance tests green, all unit tests green, Windows cross-compile clean. Two refactors landed without changing observable behavior. The codebase is ~700 LOC of Go (cmd + internal + tests) plus ~300 lines of embedded manifest. Onto Phase E: open the implementation PR.

After this PR opens, Tasks 12 (`ci.yml`) and 13 (`release.yml`) are **deferred** per the cost-min directive. Next is alpha.2 — `setup` + interactive prompts + action journal — which gets its own spec/plan/test/code cycle starting from scratch.

---

*End of alpha.1 implementation chapters. Chapters renumbered: 12-19 below are alpha.2; CI/release/tag chapters (formerly 12-15) deferred until CI re-enabled.*

---

# Part II — alpha.2: setup wizard + action journal + prompt model

> [Why a new "part" instead of continuing chapters in alpha.1's flow] Each alpha release is its own coherent unit of work with its own spec, plan, and PRs. The tutorial mirrors that. Part II chapters reference Part I's stable interfaces but a reader landing in Part II cold can still follow it without re-reading Part I.

## Chapter 12 — Scaffolding alpha.2

> [Why empty stubs first] Same reason as alpha.1's Tasks 1-2: tests need symbols to reference. We create empty-but-compiling package skeletons for `journal`, `prompt`, `identity`, and `wizard` so chapter 13's acceptance tests can `import` them and assert against their interfaces. Each stub function returns a `not implemented (Task N of alpha.2 plan)` error so test failures map cleanly to "this isn't built yet" rather than "this is broken."

### The four new packages

```text
internal/
├── journal/            # NEW — append-only NDJSON record (spec §6)
│   ├── entry.go        # Entry struct + JSON marshaling
│   ├── journal.go      # Session, Append, End — all stubs
│   └── errors.go       # errNotImplemented helper
├── prompt/             # NEW — stdin-only prompt model (spec §7)
│   ├── prompt.go       # Prompter interface + stub
│   └── unattended.go   # FromYAML(path) stub
├── identity/           # NEW — per-folder git config (spec §5 step 3)
│   └── identity.go     # SetWorkspaceIdentity / GetWorkspaceIdentity stubs
└── wizard/             # NEW — multi-step orchestrator
    ├── wizard.go       # Step interface, Context, Run() stub
    └── steps/
        ├── welcome.go  # step 1 stub
        ├── prereqs.go  # step 2 stub
        ├── identity.go # step 3 stub
        └── errors.go   # errStubStep helper
```

### The Prompter interface — design invariant

The most consequential file is `prompt/prompt.go`. It declares:

```go
// **DESIGN INVARIANT** (spec §2.B-2): plain stdin only. No TUI library.
// No survey, no bubbletea, no termbox. The PS-era TUI bug class (six
// prior commits) is exactly what we're avoiding.
type Prompter interface {
    YesNo(question, defaultAnswer string) (bool, error)
    Line(question, defaultAnswer string) (string, error)
    Quit() bool
}
```

That comment isn't decoration — it's an enforced rule. A future contributor who tries to add a survey-library dependency has to delete the comment AND restructure the wizard's test infrastructure to do it. The friction is intentional.

### The Step interface — wizard pattern

`wizard/wizard.go`:

```go
type Step interface {
    Title() string
    Run(ctx *Context) (result string, err error)
}
```

Each step is a self-contained unit. The wizard `Run([]Step, *Context)` iterates: print header, call `Run()`, print result, journal the outcome, move to next. The pattern fits on a postcard and extends cleanly through alpha.6+ (folder-creation, repo-cloning, identity steps all plug into the same interface).

`Context` holds shared dependencies (`Out`, `Prompt`, `Session`) AND state that flows between steps (`Workspace string` — set by the identity step in alpha.2; read by a future clone step in alpha.6). Mutable shared state is usually a smell; here it's the explicit cross-step communication channel.

### The stub-error pattern

Every stub returns:

```go
return fmt.Errorf("journal: NewSession not implemented (Task 3 of alpha.2 plan)")
```

When tests fail, the error message tells the reader **exactly which task implements the missing piece**. No "panic: nil pointer" mysteries; no "unexpected behavior" guessing.

### What this commit doesn't do

- No tests. Tests come in chapter 13.
- No behavior. Every function returns an error.
- No outside imports of these packages. They're islands until chapter 13's tests connect them.

State after this commit:

```text
$ go build ./...                        # exit 0
$ go test ./...                         # alpha.1 tests still GREEN
$ go test -tags acceptance ./tests/...  # 7/7 alpha.1 still GREEN (no alpha.2 tests yet)
```

Bisectable diff, ~11 new files, zero behavior change.

---

## Chapter 13 — RED phase for alpha.2

> [Outside-in TDD, second time around] Same discipline as alpha.1: write the acceptance tests first, watch them fail for the right reason, then implement. The 7 new tests in this chapter extend `tests/acceptance/acceptance_test.go` — same file, shared helpers (`buildBinary`, `run`, `fixture`).

### The unattended-config testing strategy

Acceptance tests cannot reliably drive interactive stdin. Spawning a subprocess and pumping bytes to its stdin works on Unix but is fragile on Windows (pipe buffering, terminal emulation differences, encoding edge cases). Instead, every alpha.2 acceptance test runs `setup` in `--unattended --config <path>` mode — answers come from YAML, not stdin.

This means **the unattended path needs to be a first-class implementation**, not a tacked-on `--quiet` flag. It is, per spec §2.B-8.

### Four unattended fixtures

```text
tests/acceptance/testdata/
├── unattended-happy.yaml             → all consent, no drift expected
├── unattended-drift-acknowledge.yaml → consent + continue_with_drift: true
├── unattended-drift-reject.yaml      → consent + continue_with_drift: false
└── unattended-quit.yaml              → welcome.consent: false → user quits
```

Each is ~5 lines. The `workspace_root` is injected at runtime via the `renderUnattendedConfig` helper so each test gets a clean `t.TempDir()` workspace.

### Two new test helpers

`renderUnattendedConfig(fixtureName, workspace)` copies a fixture template into the test's temp dir and appends `workspace_root: <workspace>` if missing. Returns the materialized path.

`runSetup(binPath, manifest, config, fakeHome)` is like `run()` but specifically for the setup subcommand:

```go
cmd.Env = append(os.Environ(),
    "CA_BOOTSTRAP_MANIFEST="+manifestPath,
    "HOME="+fakeHome,                        // redirect journal location
    "CA_BOOTSTRAP_ASCII=1",                  // ASCII output is greppable
)
```

`HOME=$fakeHome` is critical — it redirects the journal (`~/.ca-bootstrap/journal.ndjson`) into the test sandbox so `TestSetup_JournalRecordsSession` can verify its contents without polluting the real `$HOME`.

### The 7 tests, briefly

| # | Test | Asserts |
|---|---|---|
| 1 | `TestSetup_HappyPath_ExitsZero` | go+git fixture + consent → exit 0 |
| 2 | `TestSetup_PrereqsDrift_Acknowledged_ExitsZero` | missing-required fixture + `continue_with_drift: true` → exit 0 |
| 3 | `TestSetup_PrereqsDrift_Rejected_ExitsTwo` | missing-required fixture + `continue_with_drift: false` → exit 2 |
| 4 | `TestSetup_QuitAtPrompt_ExitsOneThirty` | `welcome.consent: false` → exit 130 |
| 5 | `TestSetup_ConfigMissing_ExitsOne` | `--config /tmp/nope.yaml` → exit 1 + 'config' in stderr |
| 6 | `TestSetup_WritesGitIdentityToWorkspace` | happy path → `workspace/.git/config` has Test User / test@example.com |
| 7 | `TestSetup_JournalRecordsSession` | happy path → journal has `session_start`, `identity_set`, `session_end` lines |

Tests 6 and 7 verify side effects on the filesystem — exactly the kind of assertion that's hard to fake. **A passing 6 and 7 mean setup is actually doing the work**, not just looping silently.

### Watching them fail

```text
$ go test -tags acceptance ./tests/acceptance/... -v
=== RUN   TestVersion_PrintsSemverCommitAndBuildTime
--- PASS (0.46s)                                              ← alpha.1 stays green
=== RUN   TestDoctor_AllToolsPresent_ExitsZero
--- PASS (0.51s)
... (5 more alpha.1 PASS)
=== RUN   TestSetup_HappyPath_ExitsZero
--- FAIL (0.48s)                                              ← alpha.2 RED starts
... (6 more alpha.2 FAIL)
```

**14 tests, 7 PASS, 7 FAIL.** The 7 PASS are alpha.1's untouched-by-this-PR contract. The 7 FAIL are alpha.2's not-yet-implemented contract. Discipline gate satisfied: no implementation lands until the contract is locked in.

### Why test failure mode matters

A FAIL because "unknown command setup" is the correct kind of FAIL — the binary built, it ran, it returned the wrong exit code because the feature is missing. A FAIL because "compile error in test file" or "fixture not found" would be a test bug. We have the former, not the latter.

### End of PR boundary

This commit closes the scaffold + RED PR. Implementation begins in chapter 14 on a new branch (`feat/alpha-2-impl`) with the journal package — chosen first because it has no dependencies on other alpha.2 packages, so it's the safest place to start GREEN-ing things.

---

*Chapter 14 — Implementing the journal — coming next task (after scaffold/RED PR merges).*

---

## Chapter 14 — The journal package (NDJSON, append-only)

> [Why this first] Journal has no dependencies on other alpha.2 packages. We start here so each subsequent package can lean on a real Append() rather than a stub. Smallest unit, no upstream.

### The implementation in 4 lines of write semantics

```go
func (s *Session) write(e Entry) error {
    if e.TS.IsZero()       { e.TS = time.Now().UTC() }
    if e.SessionID == ""   { e.SessionID = s.ID }
    line, _ := json.Marshal(e)
    _, err := s.f.Write(append(line, '\n'))
    return err
}
```

That's the whole "write" path. JSON-marshal the entry, append a newline, write to the file. **One `os.File.Write` per entry = one POSIX `write()` syscall**, which the kernel guarantees is atomic at the line boundary for files opened with `O_APPEND`.

> [Why atomic-at-line-boundary matters] If `ca-bootstrap setup` crashes mid-session (Ctrl+C, kernel panic, power loss), the journal is still readable: every line before the crash is a complete, parseable JSON entry. The undo logic in alpha.4 will rely on this — replay-up-to-last-good-line is much simpler than "did the file get corrupted?"

### The session ID

```go
func newID() string {
    var b [10]byte
    rand.Read(b[:])
    return hex.EncodeToString(b[:])
}
```

20-char hex string. **Not a full ULID** — ULIDs encode a timestamp prefix and require monotonicity guarantees across processes. We don't need either yet; we just need "different sessions get different IDs." A real ULID lib is one of those YAGNI temptations we said no to in spec §4.2.

### 5 unit tests, $HOME-redirect for hermeticity

```go
func withTestHome(t *testing.T) string {
    home := t.TempDir()
    t.Setenv("HOME", home)
    return home
}
```

Every journal test calls `withTestHome(t)` first. The journal package's `NewSession()` reads `$HOME` via `os.UserHomeDir()` to find `~/.ca-bootstrap/journal.ndjson` — `t.Setenv` redirects it into the test sandbox so we never write to the real user's home. `t.Setenv` is auto-restored at test end (Go 1.17+); no manual cleanup needed.

---

## Chapter 15 — The prompt package (stdin + unattended)

> [The design invariant, enforced by what we DIDN'T import] Look at `go.mod`. Two deps: cobra, yaml.v3. No survey. No promptui. No bubbletea. The "no TUI" rule from spec §2.B-2 is visible in the dependency graph itself — adding one would be a reviewer-visible signal.

### The interactive Prompter — `bufio.NewReader` + a tiny validation loop

```go
func (p *stdinPrompter) YesNo(question, defaultAnswer string) (bool, error) {
    hint := "[y/n]"
    switch strings.ToLower(defaultAnswer) {
    case "y": hint = "[Y/n]"
    case "n": hint = "[y/N]"
    }
    for retries := 0; retries < 5; retries++ {
        fmt.Fprintf(p.w, "%s %s ", question, hint)
        line, _ := p.r.ReadString('\n')
        ans := strings.ToLower(strings.TrimSpace(line))
        if ans == "" { ans = strings.ToLower(defaultAnswer) }
        switch ans {
        case "y", "yes": return true, nil
        case "n", "no":  return false, nil
        case "q", "quit":
            p.quitted = true
            return false, ErrQuit
        default:
            fmt.Fprintf(p.w, "  please answer y or n (q to quit)\n")
        }
    }
    return false, fmt.Errorf("prompt: too many invalid answers")
}
```

That's everything. Default hint shown via `[Y/n]` capitalization. 5-retry limit so a wedged user doesn't loop forever. `ErrQuit` sentinel for `q`. **No terminal manipulation, no cursor positioning, no ANSI sequences.** The kind of code that compiles on every platform Go runs on and behaves identically.

> [The retry loop's cost-benefit] We allow 5 invalid answers before giving up. Why not 1? A user mistyping "yse" instead of "yes" shouldn't fail the whole setup. Why not 100? A scripted environment with broken stdin should fail quickly. 5 is the smallest number that feels human-tolerant.

### The unattended Prompter — YAML keys as dotted paths

```go
func (p *unattendedPrompter) YesNo(question, defaultAnswer string) (bool, error) {
    v, ok := p.lookup(question)  // walks "welcome.consent" through map
    if !ok {
        return false, fmt.Errorf("%w: %s", errKeyMissing, question)
    }
    if b, ok := v.(bool); ok { return b, nil }
    ...
}
```

Steps call `ctx.Prompt.YesNo("welcome.consent", "y")`. The stdin Prompter prints `welcome.consent [Y/n]` (slightly ugly but consistent with YAML keys). The unattended Prompter walks the dotted path through `map[string]any`. **Same call site, two completely different behaviors.**

> [The interactive UX compromise] Showing "welcome.consent [Y/n]" instead of "Continue? [Y/n]" is uglier than the PS-era UX. Trade-off: zero risk of drift between display text and YAML key path. A future alpha can add a `prompter.YesNoNamed(key, display, default)` signature when interactive UX becomes a priority.

### 17 subtests via table-driven matrix

Eight yes/no variants × one cassette (`y/Y/yes/YES/n/N/no/NO`) + edge cases (`q`, empty-with-default, invalid retries, file not found, missing key) = comprehensive coverage in ~70 lines of test code.

---

## Chapter 16 — The identity package (per-folder git config)

> [Why shell out to git instead of writing the INI by hand] Git's config format is INI-like but has subtleties (sections, subsections, includes, quoting rules). Writing the bytes ourselves means we'd have to handle all those subtleties to stay compatible with `git config --get`. Shelling out to `git config --file <path>` lets git own its own format — and `git config` is **idempotent by default** (updates the existing key rather than appending duplicates), which gives us idempotency for free.

```go
func setGitConfigKey(cfgPath, key, value string) error {
    cmd := exec.Command("git", "config", "--file", cfgPath, key, value)
    out, err := cmd.CombinedOutput()
    if err != nil {
        return fmt.Errorf("identity: git config %s=%q: %w (output: %s)", key, value, err, strings.TrimSpace(string(out)))
    }
    return nil
}
```

The dependency on `git` being on PATH is OK: setup runs the prereqs check *first*, so by the time the identity step runs, we know `git` is installed.

### Per-folder strategy decisions

`<workspace>/.git/config` makes the workspace look like a degenerate git repo (no HEAD, no objects, just config). When users clone repos *inside* the workspace, those inner `.git/` dirs take precedence per git's standard lookup, so the workspace identity only applies to git operations run from the workspace itself (rare). For repos that need their own identity, that identity is still set normally in the cloned repo's own `.git/config`.

> [Why not includeIf in ~/.gitconfig] That's the "cleanest" git-native approach but it pollutes the user's global config, which spec §2.B-4 explicitly avoids. The degenerate-workspace approach has a slightly weird semantic but a zero-pollution outcome.

---

## Chapter 17 — The wizard orchestrator

> [The Step interface fits on a postcard] Two methods: `Title() string`, `Run(*Context) (string, error)`. Steps are pure data + a Run method. Adding a step in alpha.5 (folder taxonomy) or alpha.6 (repos) means writing one `.go` file and appending it to the `[]Step` slice in `setup.go`. No registry, no factory, no DI framework.

### Run() in 25 lines

```go
func Run(steps []Step, ctx *Context) int {
    for i, step := range steps {
        fmt.Fprintf(ctx.Out, "\nStep %d/%d — %s\n", i+1, len(steps), step.Title())
        action := normalizeAction(step.Title())
        result, err := step.Run(ctx)
        switch {
        case errors.Is(err, prompt.ErrQuit):
            fmt.Fprintln(ctx.Out, "  (user quit)")
            _ = ctx.Session.Append(journal.Entry{Action: action, Result: "quit"})
            return 130
        case errors.Is(err, ErrDriftRejected):
            _ = ctx.Session.Append(journal.Entry{Action: action, Result: "drift_rejected"})
            return 2
        case err != nil:
            fmt.Fprintln(ctx.Out, "  error:", err)
            _ = ctx.Session.Append(journal.Entry{Action: action, Result: "error"})
            return 1
        default:
            if result != "" { fmt.Fprintln(ctx.Out, "  ✓ "+result) }
            _ = ctx.Session.Append(journal.Entry{Action: action, Result: "ok"})
        }
    }
    return 0
}
```

The exit codes map 1:1 to spec §5.3. Each path writes exactly one journal entry per step. **Reading this function once tells you everything about how setup handles success, drift-rejection, quit, and errors.**

### Two sentinel errors

- `prompt.ErrQuit` — from any Prompter when the user types 'q'
- `wizard.ErrDriftRejected` — from the Prereqs step when drift was found AND user declined

Both checked via `errors.Is`. The errors-as-values pattern keeps the exit-code logic linear and exhaustive.

---

## Chapter 18 — The three steps (welcome, prereqs, identity)

Each step is ~30-50 lines. The pattern:

1. Print step-specific output via `ctx.Out`
2. Call `ctx.Prompt.YesNo(...)` or `ctx.Prompt.Line(...)` with the dotted-path key
3. On success, do the side effect (write git config, set ctx.Workspace, etc.)
4. Return the `result` string (the wizard prints it with ✓) and `nil` error

```go
func (Welcome) Run(ctx *wizard.Context) (string, error) {
    fmt.Fprintln(ctx.Out, "  Welcome to the ChannelAssist developer setup wizard.")
    ...
    ok, err := ctx.Prompt.YesNo("welcome.consent", "y")
    if err != nil { return "", err }
    if !ok       { return "", prompt.ErrQuit }
    return "Consented.", nil
}
```

The `Prereqs` step **reuses the doctor classification logic** via a small `classifyTool` helper (duplicated for now to avoid a cyclic dependency — `cli` already imports `wizard.steps`, so `steps` can't import `cli`). Refactor candidate flagged in code.

---

## Chapter 19 — The setup subcommand: 14/14 GREEN

```go
// internal/cli/setup.go
func runSetup() int {
    prompter := /* unattended or stdin */
    sess, _ := journal.NewSession()
    ctx := &wizard.Context{Out: os.Stdout, Prompt: prompter, Session: sess}
    if setupUnattended {
        if ws, _ := prompter.Line("identity.workspace_root", ""); ws != "" {
            ctx.Workspace = ws
        }
    }
    stepList := []wizard.Step{steps.Welcome{}, steps.Prereqs{}, steps.Identity{}}
    exit := wizard.Run(stepList, ctx)
    sess.End(exit)
    return exit
}
```

Cobra wiring is mechanical. The actual orchestration is the 8 lines inside `runSetup()`. **One call to `wizard.Run`** dispatches three steps and returns an exit code.

### The bug we found at integration time

First test run: 6/14 FAIL. The Welcome step was using `ctx.Prompt.YesNo("  Continue?", "y")` (the display text) instead of `ctx.Prompt.YesNo("welcome.consent", "y")` (the YAML key path). Unattended prompts couldn't find a key called `"  Continue?"`.

Fix: change all step prompts to use the dotted-path key (matching the YAML structure). UX gets slightly uglier in interactive mode (we now print `welcome.consent` instead of `Continue?`) but the unattended path is bulletproof. Documented in chapter 15 as a deliberate trade-off.

### A second bug — the test helper's YAML rendering

After the first fix: 3/14 FAIL. The `renderUnattendedConfig` test helper was appending `workspace_root` to the END of the YAML file:

```yaml
identity:
  name: "Test User"
  email: "test@example.com"
  # workspace_root is filled in...

  workspace_root: "/tmp/..."   ← this blank line breaks the identity: block
```

YAML's indent-based parser saw the blank line + new indented key as breaking the `identity:` mapping → `workspace_root` became a top-level key → the unattended Prompter's `identity.workspace_root` lookup failed.

Fix: inject `workspace_root` *immediately after* `email:` (no blank line in between). Test helper now does:

```go
emailLine := "  email: \"test@example.com\""
body = strings.Replace(body, emailLine, emailLine+"\n  workspace_root: \""+workspace+"\"", 1)
```

> [TDD-shaped because the helper was test code, not impl code] Test infrastructure bugs are sometimes worse than production bugs — they erode trust in the test suite. The discipline: fix them visibly, document them, move on. The fix landed in the same commit as the implementation it enabled.

### The final state

```text
$ go test -tags acceptance ./tests/acceptance/... -v
--- PASS: TestVersion_PrintsSemverCommitAndBuildTime         (alpha.1)
--- PASS: TestDoctor_AllToolsPresent_ExitsZero               (alpha.1)
--- PASS: TestDoctor_RequiredToolMissing_ExitsTwo            (alpha.1)
--- PASS: TestDoctor_RequiredToolBelowMin_ExitsTwo           (alpha.1)
--- PASS: TestDoctor_OptionalToolMissing_ExitsZeroWithWarning (alpha.1)
--- PASS: TestDoctor_ManifestMissing_ExitsOneToStderr        (alpha.1)
--- PASS: TestDoctor_ManifestParseError_ExitsOneToStderr     (alpha.1)
--- PASS: TestSetup_HappyPath_ExitsZero                      (alpha.2)
--- PASS: TestSetup_PrereqsDrift_Acknowledged_ExitsZero      (alpha.2)
--- PASS: TestSetup_PrereqsDrift_Rejected_ExitsTwo           (alpha.2)
--- PASS: TestSetup_QuitAtPrompt_ExitsOneThirty              (alpha.2)
--- PASS: TestSetup_ConfigMissing_ExitsOne                   (alpha.2)
--- PASS: TestSetup_WritesGitIdentityToWorkspace             (alpha.2)
--- PASS: TestSetup_JournalRecordsSession                    (alpha.2)
PASS  (14/14)
ok    github.com/ChannelAssist/ca-bootstrap/tests/acceptance    7.328s
```

**14/14.** alpha.2 functional surface = `setup` interactive wizard with `welcome` + `prereqs` + `identity` steps, action journal recording, prompt model with unattended-YAML support. The whole thing is roughly 600 lines of Go + 300 lines of test code + 17 fixtures.

### What's deferred

- **Real-binary smoke run on Windows** — we cross-compile but don't run there yet. Lands in the eventual release-pipeline PR.
- **Tasks 9 (refactor)** — there's duplication between `cli/doctor.go`'s `classify` and `wizard/steps/prereqs.go`'s `classifyTool`. Worth extracting to a shared utility once alpha.3's `repair` lands and we have a third caller.

---

*End of alpha.2 implementation chapters. Next subsystem (alpha.3 — `repair`) gets its own spec / plan / RED / GREEN cycle.*

---

# Part III — alpha.3: the `repair` subsystem

## Chapter 20 — Extending the manifest + RED for repair

> [The first schema change to shipped data] alpha.1 embedded `tools.yaml` with the `install:` block parsed as an opaque `yaml.Node` (doctor never read it). alpha.3 needs to actually dispatch installers, so the install block becomes a **typed `InstallSpec`**. The risk: the embedded 16-tool manifest must keep parsing. The test `TestLoad_ParsesInstallBlock` is the guard — it asserts git's winget/brew/apt-dnf targets, pwsh's brew cask, dotnet's linux-any script, and claude-code's npm-global all survive the typing.

> [Why typed now and not in alpha.1] YAGNI. alpha.1's doctor only needed `detect:`. Typing `install:` then would have been speculative. Now repair needs it, so now it gets typed — driven by an actual consumer, not a guess.

### The mock install type

repair's acceptance tests can't run real `brew install` / `apt-get install` — they'd mutate the CI runner and need network + privileges. The solution is data-driven: a fixture manifest declares `install: { any: { type: mock, id: fail } }`. The real installer dispatch (chapter 23) recognizes `type: mock` and returns canned outcomes (`fail` → Failed, `needs-elevation` → triggers the elevation flow). Production manifests never use `type: mock`, so production never hits it.

> [Why data-driven mock vs env-var mock] An earlier draft used `$CA_BOOTSTRAP_INSTALLER_OVERRIDE=mock`. The data-driven approach is cleaner: the test's intent is visible in the fixture (`type: mock, id: fail`), not hidden in an env var, and there's no global-state flag to leak between tests.

### 5 acceptance tests (RED)

| Test | Drives | Expected |
|---|---|---|
| `TargetNotInManifest_ExitsOne` | `--target nonexistent` | exit 1 + stderr |
| `AlreadyInstalled_ExitsZeroNoOp` | `--target git` (present) | exit 0, no install |
| `InstallFailure_ExitsTwo` | mock `id: fail` | exit 2 |
| `ElevationDeclined_ExitsOneThirty` | mock elevation + `elevation_action: deny` | exit 130 |
| `ElevationSkipChosen_ExitsTwoWithManual` | mock elevation + `elevation_action: skip` | exit 2 + manual summary |

Lock acquire/release/force-unlock are **unit-tested** in `internal/lock` (chapter 26), not acceptance-tested — `flock` is tied to an open file descriptor and can't be "held" by a separate test process via a marker file.

All 5 fail because `repair` isn't a registered subcommand yet. RED gate satisfied.

---

*Chapters 21-28 (installer dispatch, elevation, lock, repair command) land with the implementation.*

## Chapters 21-28 — alpha.3 implementation (condensed)

> [Why condensed] alpha.1 and alpha.2 chapters are exhaustively detailed because they introduce the project's patterns. alpha.3 reuses those patterns (interface + platform build-tags + table-driven tests + outside-in acceptance). This section covers what's *new* in alpha.3 rather than re-explaining established mechanics.

### Ch 21 — the install package shape

Same platform-polymorphism as `detect`: a shared `genericInstaller` holds the cross-platform flow (mock short-circuit, elevation decision), delegating actual command execution to a build-tag-selected `targetExecutor` (`install_unix.go` / `install_windows.go`). The `Installer` interface has one method; `Default()` returns the platform impl.

### Ch 22 — the mock install type

`type: mock` in a fixture manifest short-circuits `genericInstaller.Install` to canned results (`id: fail` → Failed, `id: needs-elevation` → triggers the elevation decision). This is how acceptance tests exercise the install flow without running real `brew`/`apt`. Production manifests never use `type: mock`.

### Ch 23 — command construction, tested without running

`buildUnixCommand(target, elevated)` returns a *string* — pure, table-testable. The actual `exec.Command("sh", "-c", cmdline)` is a separate `runShell` step. Separating construction from execution means we unit-test the dangerous part (what command gets built, does `sudo` get prepended) without ever running an installer in CI.

### Ch 24 — Windows elevation via PowerShell RunAs

`install_windows.go` wraps elevated commands in `Start-Process -Verb RunAs` (the UAC trigger). Cross-compile-verified only — the real UAC flow needs a Windows host + interactive session, deferred to manual smoke when CI is re-enabled.

### Ch 25 — elevation rules as a pure function

`NeedsElevation(InstallTarget) bool` — 10 table-test rows. apt/dnf/snap → true; brew/npm/user-winget → false; script-with-sudo → true. Pure, no OS calls. The "should we even ask for a password?" decision is one testable function.

### Ch 26 — cross-platform file locking, two implementations

`internal/lock` mirrors `internal/detect`'s build-tag split: `lock_unix.go` uses `syscall.Flock(LOCK_EX|LOCK_NB)`; `lock_windows.go` uses `golang.org/x/sys/windows.LockFileEx`. The Unix path has 3 unit tests (acquire/release, second-acquire-fails, force-unlock). The Windows path is **cross-compile-verified only** — `flock` can't be faked across test processes, and there's no Windows runner yet.

> [The one new dependency] `golang.org/x/sys` — the canonical low-level syscall package (Go-team maintained, stdlib-adjacent). Pinned to v0.20.0 to keep the go directive at 1.23 (v0.45 would have forced 1.25). This is the first dep added since cobra+yaml.v3; justified because raw `syscall.NewLazyDLL("kernel32.dll")` for `LockFileEx` is far more error-prone and equally untestable on macOS.

### Ch 27 — the repair command: lock → find → probe → install → verify

`runRepair()` is a linear pipeline with explicit exit codes at each gate:
1. Acquire session lock (`--ForceUnlock` breaks stale) → exit 1 on failure
2. Find `--target` in manifest → exit 1 if absent
3. Probe — already installed? → exit 0 no-op
4. Install via `install.Default().Install(tool, opts)`
5. Switch on `Result.Status`: Installed → re-probe to verify → exit 0/2; Failed → 2; Declined → 130; Skipped → manual summary + 2
6. Every outcome journaled (`install_attempt`/`install_success`/`install_failed`/`install_skipped`/`manual_install_required`)

### Ch 28 — REFACTOR: paying down the alpha.2 classification debt

alpha.2 flagged a duplication: `cli/doctor.go`'s `classify` and `wizard/steps/prereqs.go`'s `classifyTool` were identical. alpha.3 added a *third* would-be caller (`repair`). Rather than triple the copy, we extracted `detect.Classify(tool, Result) Classification` into the `detect` package (which both `cli` and `wizard/steps` already import — no cycle). Three call sites, one rule. All 19 acceptance + every unit test stayed green through the extraction — the safety net working as designed.

### State at end of alpha.3 implementation

```text
$ go vet ./...                                  # exit 0
$ go test ./...                                 # all unit/integration PASS
$ go test -tags acceptance ./tests/...          # 19/19 PASS (7+7+5)
$ GOOS=windows go vet ./...                     # exit 0
```

`ca-bootstrap` now has four verbs: `version`, `doctor`, `setup`, `repair`. The next subsystem (alpha.4 — `undo`) replays the action journal in reverse to uninstall what `repair` installed.

---

*End of Part III. alpha.4 (`undo`) is the next subsystem.*
