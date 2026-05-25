# ca-bootstrap v2.0.0-alpha.2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` to execute task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ca-bootstrap v2.0.0-alpha.2` — add `setup` interactive wizard (welcome / prereqs / identity) on top of alpha.1's `version` + `doctor`. Introduce action journal (NDJSON) and prompt model (plain stdin, no TUI).

**Architecture:** Four new packages — `internal/prompt`, `internal/journal`, `internal/identity`, `internal/wizard` — plus `internal/cli/setup.go`. The wizard is a slice of pluggable `Step` values; each step writes to the journal on completion. The prompt interface has two implementations (stdin / unattended-from-YAML) injectable by tests.

**Tech Stack:** Go 1.23+, existing deps only (cobra, yaml.v3, stdlib). No new external dependencies in alpha.2.

**Process discipline:** Outside-in TDD. ~7 acceptance tests + per-package unit tests written first (RED). Implement smallest-thing-at-a-time to GREEN. Tutorial doc (`docs/tutorials/tdd-walkthrough.md`) gains chapters 12-19 inside the same commits as the corresponding code.

**Spec reference:** [`docs/specs/2026-05-25-go-v2-0-alpha-2-spec.md`](../specs/2026-05-25-go-v2-0-alpha-2-spec.md). **The 10 design decisions in spec §2.B are AI judgment calls — please confirm or redirect before implementation begins.**

---

## File structure (new in alpha.2)

| Path | Responsibility | Created in task |
|---|---|---|
| `internal/journal/entry.go` | `Entry` struct + JSON marshaling | Task 3 |
| `internal/journal/journal.go` | `NewSession`, `Append`, `End` (file open + append). NO locking — session locking is deferred to alpha.3 (spec §2.B-5). | Task 3 |
| `internal/journal/journal_test.go` | Unit tests for append/iterate/session boundaries | Task 3 |
| `internal/prompt/prompt.go` | `Prompter` interface + stdin implementation | Task 4 |
| `internal/prompt/unattended.go` | YAML-config-backed implementation | Task 4 |
| `internal/prompt/prompt_test.go` | Unit tests with `bytes.Buffer`-injected stdin | Task 4 |
| `internal/identity/identity.go` | Read/write per-folder git config | Task 5 |
| `internal/identity/identity_test.go` | Unit tests with `t.TempDir()` workspaces | Task 5 |
| `internal/wizard/wizard.go` | `Step` interface + `Run(steps []Step, ctx Context) int` | Task 6 |
| `internal/wizard/wizard_test.go` | Unit tests with stub steps + stub prompter | Task 6 |
| `internal/wizard/steps/welcome.go` | Step 1: banner + Y/n consent | Task 7 |
| `internal/wizard/steps/prereqs.go` | Step 2: reuses internal/detect + reports drift | Task 7 |
| `internal/wizard/steps/identity.go` | Step 3: prompt for name/email + write workspace .git/config | Task 7 |
| `internal/cli/setup.go` | Cobra `setup` subcommand wiring everything together | Task 8 |
| `tests/acceptance/acceptance_test.go` | Extend with 7 alpha.2 acceptance tests | Task 2 |
| `tests/acceptance/testdata/unattended-*.yaml` | Fixture configs for `--unattended` scenarios | Task 2 |
| `docs/tutorials/tdd-walkthrough.md` | Chapters 12-19 | Each task |

---

## Branch and PR strategy

| Branch | Contains | Depends on |
|---|---|---|
| `chore/alpha-2-scaffold-and-red` | Tasks 1-2 (skeleton + RED tests + tutorial ch 12-13) | #88 + #89 merged |
| `feat/alpha-2-impl` | Tasks 3-9 (impl + refactor + tutorial ch 14-19) | scaffold PR |

Two PRs after morning decisions confirmed.

---

## Task 1 — Package scaffold (skeleton-only, no behavior)

**Files:**
- Create: `internal/journal/{entry,journal}.go` (stubs)
- Create: `internal/prompt/{prompt,unattended}.go` (stubs)
- Create: `internal/identity/identity.go` (stub)
- Create: `internal/wizard/wizard.go` (stub)
- Create: `internal/wizard/steps/{welcome,prereqs,identity}.go` (stubs)
- Update: `docs/tutorials/tdd-walkthrough.md` (chapter 12 — scaffolding alpha.2)

**Branch:** `chore/alpha-2-scaffold-and-red` off `dev` (after #89 merges; or locally rebased onto migration tip)

- [ ] **Step 1:** Create directory structure

```bash
mkdir -p internal/journal internal/prompt internal/identity internal/wizard/steps
```

- [ ] **Step 2: Write stub for each package**

Each stub file contains: package declaration + 1-line comment + a TODO declaration that compiles but does nothing. Example for `internal/journal/journal.go`:

```go
// Package journal is the append-only NDJSON action record at
// ~/.ca-bootstrap/journal.ndjson. See spec §6.
//
// Implementation lands in Task 3 — this file is a scaffold so Task 2's
// acceptance tests can reference the package symbols.
package journal

import "time"

// Entry is one journal record. See spec §6.1 for the schema.
type Entry struct {
	TS        time.Time         `json:"ts"`
	SessionID string            `json:"sessionID"`
	Action    string            `json:"action"`
	Target    string            `json:"target,omitempty"`
	Before    map[string]string `json:"before,omitempty"`
	After     map[string]string `json:"after,omitempty"`
	Result    string            `json:"result"`
}
```

Repeat for the other packages with their public type/method signatures.

- [ ] **Step 3: Confirm it compiles**

```bash
go build ./...
echo "exit=$?"
```

Expected: exit 0. No symbols referenced yet — just empty package scaffolds.

- [ ] **Step 4: Tutorial chapter 12 — "alpha.2 scaffolding"**

Append to `docs/tutorials/tdd-walkthrough.md`. Cover: why we start with empty package skeletons (Task 2's tests need symbols to reference), the package boundaries we chose (journal/prompt/identity/wizard), and the relationship to spec §4.

- [ ] **Step 5: Commit**

```bash
git add internal/ docs/tutorials/tdd-walkthrough.md
git commit -S -m "chore(alpha-2): scaffold journal/prompt/identity/wizard packages (AB#<NEW>)"
```

---

## Task 2 — RED phase: 7 acceptance tests + unit-test scaffolding

**Files:**
- Modify: `tests/acceptance/acceptance_test.go` (add 7 alpha.2 tests)
- Create: `tests/acceptance/testdata/unattended-{happy,drift-acknowledge,drift-reject,quit}.yaml`
- Create: stub `*_test.go` files for journal/prompt/identity/wizard
- Update: tutorial chapter 13 — "RED for alpha.2"

**Branch:** continue on `chore/alpha-2-scaffold-and-red`

- [ ] **Step 1: Create unattended fixture configs**

`testdata/unattended-happy.yaml`:

```yaml
welcome:
  consent: true
prereqs:
  continue_with_drift: true
identity:
  name: "Test User"
  email: "test@example.com"
  workspace_root: "/tmp/ca-bootstrap-acceptance"
```

`testdata/unattended-drift-acknowledge.yaml`, `unattended-drift-reject.yaml`, `unattended-quit.yaml` follow the same shape with different values.

- [ ] **Step 2: Extend `acceptance_test.go` with 7 alpha.2 tests**

Add (using the existing helpers `buildBinary`, `run`):

```go
func TestSetup_HappyPath_ExitsZero(t *testing.T) {
    bin := buildBinary(t)
    cfg := fixture(t, "unattended-happy.yaml")
    // Use the embedded manifest so all required tools are present
    // (CI runners have go + git + the rest).
    _, _, exit := run(t, bin, "" /* use embedded */, "setup", "--unattended", "--config", cfg)
    if exit != 0 {
        t.Fatalf("expected exit 0, got %d", exit)
    }
}

func TestSetup_PrereqsDrift_Acknowledged_ExitsZero(t *testing.T) { ... }
func TestSetup_PrereqsDrift_Rejected_ExitsTwo(t *testing.T)      { ... }
func TestSetup_QuitAtPrompt_ExitsOneThirty(t *testing.T)         { ... }
func TestSetup_ConfigMissing_ExitsOne(t *testing.T)              { ... }
func TestSetup_WritesGitIdentityToWorkspace(t *testing.T)        { ... }
func TestSetup_JournalRecordsSession(t *testing.T)               { ... }
```

(Full code in commit; abbreviated here for plan brevity.)

- [ ] **Step 3: Verify RED — all 7 fail**

```bash
go test -tags acceptance ./tests/acceptance/... -run TestSetup -v 2>&1 | tail -20
```

Expected: 7/7 FAIL because `setup` subcommand doesn't exist yet. Failure mode should be "unknown command setup" → cobra prints help → exit 1, which the tests assert against not-1 for happy cases.

- [ ] **Step 4: Tutorial chapter 13 — "RED for alpha.2"**

Cover: how the 7 alpha.2 tests extend the 7 alpha.1 tests (shared `buildBinary`/`run` helpers), why we use `--unattended` for ALL acceptance tests (acceptance tests can't drive interactive stdin reliably), the choice of fixture filename convention.

- [ ] **Step 5: Commit**

```bash
git commit -S -m "test(alpha-2): 7 failing acceptance tests + fixtures (AB#<NEW>)"
```

**End of `chore/alpha-2-scaffold-and-red` PR.** Push + open PR — first PR for alpha.2 work.

---

## Task 3 — Journal package + tests

**Branch:** new `feat/alpha-2-impl` off `chore/alpha-2-scaffold-and-red`.

- [ ] **Step 1: Write `internal/journal/journal_test.go` FIRST** — unit tests for:
  - `NewSession` returns a non-empty ULID-shaped string
  - `Append(entry)` writes to a file in `~/.ca-bootstrap/` (use `t.TempDir()` + env override of journal path)
  - `Iterate(fn)` walks every line in order
  - Crash safety: a partial line is not returned

- [ ] **Step 2: Verify RED** (`Append`, `NewSession`, etc. undefined)

- [ ] **Step 3: Implement `journal.go`** — `Append` opens file with `O_APPEND|O_CREATE|O_WRONLY` (mode 0600), marshals entry to JSON, writes `line + \n`. Each record is a single `write()` — small enough to land in one syscall in practice, but **not** a POSIX cross-process atomicity guarantee (see spec §2.B-3); the alpha.3 session lock is what actually prevents interleaving. Random-hex session IDs via tiny inline impl (no external dep).

- [ ] **Step 4: Verify GREEN**

- [ ] **Step 5: Tutorial chapter 14 — "the action journal"**

- [ ] **Step 6: Commit**

---

## Task 4 — Prompt package + tests

- [ ] **Step 1: Write `internal/prompt/prompt_test.go` FIRST** — `bytes.Buffer`-backed stdin tests:
  - `YesNo` accepts y, Y, yes, "" (default-y), retries on invalid
  - `Line` returns default on empty input
  - `q` triggers `Quit()`
  - unattendedPrompter pulls from a `map[string]any`; missing key = error

- [ ] **Step 2-5:** RED → impl → GREEN → tutorial chapter 15 — "the prompt model (no TUI)"

- [ ] **Step 6: Commit**

---

## Task 5 — Identity package + tests

- [ ] **Step 1: `identity_test.go`** — given a `t.TempDir()` "workspace," call `SetIdentity(name, email)`, then read the file at `workspaceRoot/.git/config` and assert content. Verify `git config --local user.name` returns the expected value when run from inside.

- [ ] **Steps 2-5:** RED → impl using `git config --local` via `exec.Command` → GREEN → tutorial chapter 16 — "per-folder git identity"

- [ ] **Step 6: Commit**

---

## Task 6 — Wizard orchestrator + Step interface

- [ ] **Step 1: `wizard_test.go`** — `Step` interface (Title, Run); table-driven tests with stub steps that record their invocations; tests Quit() interruption flow, journal-on-completion, error propagation.

- [ ] **Steps 2-5:** RED → impl → GREEN → tutorial chapter 17 — "the wizard pattern"

- [ ] **Step 6: Commit**

---

## Task 7 — Implement the 3 steps (welcome, prereqs, identity)

- [ ] **Steps 1-5 (per step):** Write step-specific integration tests (using stub Prompter + stub Detector + bytes.Buffer for output), then implement each step (welcome.go, prereqs.go, identity.go). Each step is ~30-50 LOC.

- [ ] **Step 6: Tutorial chapter 18 — "wiring the three steps"**

- [ ] **Step 7: Commit** (one commit per step, or one bundled if tight)

---

## Task 8 — `setup` subcommand → ALL 14 acceptance tests GREEN

- [ ] **Step 1: Create `internal/cli/setup.go`** with cobra subcommand that:
  - Reads `--unattended --config <path>` (or uses interactive defaults)
  - Constructs a slice of `Step` values
  - Calls `wizard.Run(steps, ctx)`
  - Exits with the wizard's return code

- [ ] **Step 2: Verify** — `go test -tags acceptance ./tests/...` reports **14/14 GREEN** (7 alpha.1 + 7 alpha.2).

- [ ] **Step 3: Real-binary smoke run** — interactive mode against actual workspace; confirm prompts work and no freezing.

- [ ] **Step 4: Tutorial chapter 19 — "all 14 green: the first wizard"**

- [ ] **Step 5: Commit**

---

## Task 9 — REFACTOR pass

- [ ] Extract any duplication; consolidate step glyphs/output formatting; ensure ASCII fallback works for setup output too.
- [ ] All tests stay GREEN.
- [ ] Tutorial chapter 20 (optional — only if substantive changes warrant).
- [ ] Commit (one logical refactor per commit).

---

## Task 10 — Open implementation PR (Phase E reached)

- [ ] Push `feat/alpha-2-impl`.
- [ ] Open PR with all 12 metadata fields per `pr-metadata-checklist`. Base: `chore/alpha-2-scaffold-and-red`.
- [ ] Title: `feat(alpha-2): implement setup wizard + journal + prompts — 14/14 acceptance GREEN (AB#<NEW>)`.
- [ ] Body mirrors alpha.1's PR #90 body shape.

---

## Self-review

**Spec coverage check:** Each section of `2026-05-25-go-v2-0-alpha-2-spec.md` mapped to one or more tasks:

| Spec § | Covered by |
|---|---|
| §2.B.2 Prompt model | Task 4 |
| §2.B.3 Action journal | Task 3 |
| §2.B.4 Identity scope | Task 5 |
| §2.B.6 Quit/SIGINT | Task 4 (Quit) + Task 6 (SIGINT trap in wizard.Run) |
| §2.B.8 `--unattended` config | Task 4 (unattendedPrompter) + Task 8 (setup loads YAML) |
| §4 Architecture | Tasks 1, 3-8 |
| §5 setup functional spec | Tasks 7, 8 |
| §6 journal spec | Task 3 |
| §7 prompt spec | Task 4 |
| §8 acceptance tests | Task 2 (RED) + Task 8 (GREEN gate) |

**Placeholder scan:** `AB#<NEW>` markers in commit-message templates. File the PBI for the scaffold/RED PR + a separate one for impl before committing; verify via `az boards work-item show`.

**Type consistency:** `Entry`, `Prompter`, `Step`, `Detector` (existing), `manifest.Tool` (existing) — names used consistently across tasks. `journal.Append(Entry)` signature used in Tasks 3, 6, 7, 8.

## Execution

Inline execution recommended (same rationale as alpha.1 plan: tutorial chapters get authored alongside the work as the live record).
