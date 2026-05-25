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

*Chapter 2 — Scaffolding the Go module — coming next task.*
