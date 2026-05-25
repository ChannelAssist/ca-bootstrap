# ca-bootstrap v2.0.0-alpha.2 — implementation spec

- **Date:** 2026-05-25 (authored overnight by Claude Code, autonomously, per Peter's directive)
- **Author:** Claude Code (AI-assisted) — **all section-2 decisions are AI-made judgment calls** awaiting Peter's morning review
- **Status:** Draft → pending Peter review (especially the decisions in §2.B)
- **Work item:** TBD — file new PBI before opening any alpha.2 PR
- **Builds on:** [`docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`](2026-05-25-go-v2-0-alpha-1-spec.md), [`docs/specs/2026-05-25-go-rewrite-pivot.md`](2026-05-25-go-rewrite-pivot.md)

## 1. TL;DR

`v2.0.0-alpha.2` extends the Go CLI with a **setup wizard** (`ca-bootstrap setup`) covering the three highest-value first-use steps: **welcome / consent → prerequisites check → git identity configuration**. Introduces the **action journal** (append-only JSON Lines record at `~/.ca-bootstrap/journal.ndjson`) so a future `undo` can reverse anything `setup` did. Introduces the **prompt model** — plain-stdin / Read line, NO TUI, NO survey library — chosen explicitly to escape the PS-era stdio-bug class. Tool installation (when the prereqs check finds missing tools) is **deferred to alpha.3** (`repair`); alpha.2's setup reports drift and exits with a friendly "run `repair` next" message.

## 2. Decisions

### 2.A — Decisions carried from alpha.1 (no change)

| Decision | Value (unchanged) |
|---|---|
| Repo layout | In-place; PS at `legacy/`, Go at root |
| Binary name | `ca-bootstrap` |
| Version line | v2.0.0 semver with `-alpha.N` pre-release tags |
| Manifest format | YAML (at `internal/manifest/`) |
| Telemetry | **None ever.** No phone-home. |
| Code signing | Defer to v2.0.0 final |
| CI matrix | 5 platforms when re-enabled |
| TUI library | None — plain CLI |
| Dependencies | Minimal: cobra, yaml.v3, stdlib. Add only with explicit rationale. |

### 2.B — New decisions for alpha.2 (AI judgment calls, awaiting Peter's review)

These were decided autonomously overnight per Peter's directive ("I'll make judgment calls without asking"). Each one is reasoned to a sensible default; please redirect anything that doesn't match your intent.

| # | Decision | Choice | Reasoning |
|---|---|---|---|
| 1 | **alpha.2 scope** | welcome + prereqs-check + identity-config only. NO install, NO folder structure, NO repo cloning. | Smallest feature surface that still feels like a wizard; install is a meaningful enough concern to deserve its own alpha (alpha.3 = `repair`). |
| 2 | **Prompt model** | **stdin/stdout only.** `bufio.NewReader(os.Stdin).ReadString('\n')` for input; default-on-Enter; `--unattended --config <path>` reads answers from YAML. | No TUI library. No survey library. The PS-era TUI bug class (six prior commits, see pivot doc § 2.2) is the literal reason we're rewriting; we will not reintroduce that surface area. Stdlib stdin is rock-solid across all 5 release platforms. |
| 3 | **Action journal format** | Append-only JSON Lines (`.ndjson`) at `~/.ca-bootstrap/journal.ndjson`. One line = one event. Schema: `{ts, sessionID, action, target, before, after, result}`. | JSONL is greppable, append-safe across crashes (one line = one atomic write on POSIX), and parseable line-by-line for undo replay. No DB, no nested format. |
| 4 | **Identity scope** | Per-folder git identity (mirrors PS era). Setup writes git config to the workspace root, not global. | Avoids polluting the user's `~/.gitconfig` for non-ChannelAssist repos. Same UX as v1.9.0 — onboarding hires expect this. |
| 5 | **Session lock** | Skip for alpha.2 v0. Concurrent-run protection arrives in alpha.3 (when `repair` actually mutates external state in parallel-unsafe ways). | Setup in alpha.2 mostly *reads* (prereqs check) + does ONE folder-scoped git config write. The cost of corrupting that is low; the cost of building a Windows-compatible file-lock now is unwarranted YAGNI. |
| 6 | **Quit / Ctrl+C** | Trap SIGINT, write a `quit` journal entry, exit 130 (conventional SIGINT exit). | Standard CLI behavior; the journal entry lets future `undo` know a setup was interrupted. |
| 7 | **Welcome consent** | Print a short banner + 1-paragraph description + Y/n prompt. Empty input = "Y". `q` quits. | Matches PS-era UX exactly. Hires expect this. |
| 8 | **`--unattended` config schema** | YAML with one top-level key per wizard step: `welcome.consent: true`, `identity.{name, email}`, `prereqs.continue_with_drift: false`. | Forward-compatible — alpha.3+ adds keys without breaking alpha.2 configs. |
| 9 | **Stale journal cleanup** | None in alpha.2. The journal grows unbounded; cleanup logic is alpha.4 (`undo --all` truncates or archives). | YAGNI. The journal is line-based ndjson; users on dev boxes will rarely exceed 1MB. |
| 10 | **Output style for setup steps** | Step header (`Step N/M — Title`) + body indented 2 spaces + result line. Same as PS era's step output (`legacy/lib/ui.ps1`). | Hires recognize this. Familiarity reduces UX risk. |

If any of the above is wrong, redirect in the morning and I'll amend the spec + adjust the plan before any code lands.

## 3. Non-goals (explicitly OUT of alpha.2)

- **Tool installation.** alpha.2's prereqs check reports drift and exits 2 with "run `ca-bootstrap repair` next" (the binary doesn't yet have `repair`; this is a forward-looking message). Install logic = alpha.3.
- **Folder structure / `ca-*` taxonomy.** alpha.5+. The PS-era logic in `legacy/lib/folders.ps1` will be ported then.
- **Repo cloning.** alpha.6+. The PS-era logic in `legacy/manifest/repos.yaml` + `legacy/steps/60-repos.ps1` ports later.
- **VS Code workspace / `.vscode/` setup.** alpha.7+.
- **Authentication (`gh auth login`).** alpha.3+ (once we have `repair`, auth can be a repair target).
- **TUI.** Forever no.
- **Session locking.** alpha.3 introduces it when needed.

## 4. Architecture additions on top of alpha.1

### 4.1 New Go packages

```
internal/
├── cli/                          # existing
│   └── setup.go                 # NEW: cobra subcommand + wizard runner
├── prompt/                       # NEW: interactive stdin/stdout prompts
│   ├── prompt.go                # interface + stdin implementation
│   ├── prompt_test.go
│   └── unattended.go            # YAML-config-backed implementation
├── journal/                      # NEW: action journal (NDJSON)
│   ├── journal.go               # Append / Iterate / Sessions
│   ├── journal_test.go
│   └── entry.go                 # Entry struct + JSON encoding
├── identity/                     # NEW: git identity config
│   ├── identity.go              # Read/write per-folder git config
│   └── identity_test.go
└── wizard/                       # NEW: step orchestrator
    ├── wizard.go                # Step interface + Run
    ├── wizard_test.go
    └── steps/
        ├── welcome.go           # Step 1: banner + consent
        ├── prereqs.go           # Step 2: reuse doctor logic
        └── identity.go          # Step 3: prompt + write per-folder git config
```

### 4.2 No new top-level deps

cobra (already) + yaml.v3 (already) cover this. The prompt package uses only stdlib.

## 5. Functional spec — `setup`

### 5.1 Behavior — interactive mode (default)

```text
$ ca-bootstrap setup
ca-bootstrap — preparing your environment

  Welcome to the ChannelAssist developer setup wizard.
  This will check installed tooling, configure your git identity
  for ChannelAssist repos, and (in a future release) clone the
  repos you need. Every step is optional. Quit any time with 'q'.

Step 1/3 — Welcome
  Continue? [Y/n/q]  Y
  ✓ Consented.

Step 2/3 — Prerequisites
  Checking installed tooling (same logic as `doctor`)...
    ✓ git           2.54.0   (manifest min: 2.40.0)
    ✓ gh            2.92.0   (manifest min: 2.30.0)
    ✗ dotnet-10     missing  → run `ca-bootstrap repair --target dotnet-10` later
  3 required tools checked: 2 ok, 1 drift.

  Continue with drift? [y/N/q]  y
  ✓ Acknowledged. Drift will be addressed by `repair` (alpha.3).

Step 3/3 — Git identity
  Workspace location: ~/Documents/Projects/ChannelAssistDev
  Configure git identity for this workspace?
    name  [Peter Giannopoulos]:
    email [peter.g@channelassist.com]:
  ✓ Wrote workspace .git/config (will inherit to clones inside this folder).

ca-bootstrap setup complete.
Next: `ca-bootstrap repair` (alpha.3) to install missing tools, then
clone your repos (alpha.6).
```

### 5.2 Behavior — unattended mode

```text
$ ca-bootstrap setup --unattended --config ./onboard.yaml
```

Reads:

```yaml
# onboard.yaml
welcome:
  consent: true
prereqs:
  continue_with_drift: true
identity:
  name: Peter Giannopoulos
  email: peter.g@channelassist.com
  workspace_root: /Users/peter/Documents/Projects/ChannelAssistDev
```

Same step output but no prompts; all answers from the config. Exits non-zero on any required answer missing.

### 5.3 Exit codes

| Exit | Meaning |
|---|---|
| `0` | All steps completed (with or without drift acknowledged) |
| `1` | System error (manifest missing, git not installed, config file unreadable, etc.) |
| `2` | Drift found AND user declined to continue (interactive) OR config said `continue_with_drift: false` |
| `130` | User quit (SIGINT or `q` at any prompt) |

## 6. Functional spec — action journal

### 6.1 Entry schema

```json
{
  "ts": "2026-05-26T03:14:15Z",
  "sessionID": "01HXNQ7K8P9...",
  "action": "git_config_set",
  "target": "/Users/peter/Documents/Projects/ChannelAssistDev/.git/config",
  "before": {"user.name": "", "user.email": ""},
  "after":  {"user.name": "Peter Giannopoulos", "user.email": "peter.g@channelassist.com"},
  "result": "ok"
}
```

### 6.2 Operations (alpha.2 surface)

| Operation | Caller | Purpose |
|---|---|---|
| `journal.Append(entry)` | each wizard step on success | record what was done |
| `journal.NewSession()` | setup entry | generate sessionID (ULID), record `session_start` |
| `journal.EndSession(rc)` | setup exit | record `session_end` with exit code |
| `journal.Iterate(fn)` | (not used in alpha.2; alpha.4 `undo` will) | line-by-line iteration |

### 6.3 Storage

`~/.ca-bootstrap/journal.ndjson`. Created with mode 0644 on first write. Permission errors at write time → exit 1 with clear message.

## 7. Functional spec — prompt model

### 7.1 The `Prompter` interface

```go
type Prompter interface {
    YesNo(question, defaultAnswer string) (bool, error)
    Line(question, defaultAnswer string) (string, error)
    Quit() // graceful exit; called on 'q' or SIGINT
}
```

Two implementations:
- `stdinPrompter` (default for interactive mode) — `bufio.NewReader(os.Stdin)` + simple validation loop
- `unattendedPrompter` (for `--unattended`) — reads from a YAML-loaded map; missing key = error

Tests inject a `stubPrompter` that returns canned answers.

### 7.2 Quit handling

- `q` (or `Q`) at any prompt → `Quit()`.
- SIGINT (Ctrl+C) → signal handler calls `Quit()`.
- `Quit()` writes a `quit` journal entry and exits 130.

## 8. Acceptance tests (the alpha.2 RED gate)

Following the alpha.1 pattern: 7-ish hermetic acceptance tests at `tests/acceptance/` with build tag `acceptance`. **These must exist and fail before any non-test alpha.2 code is committed.**

```go
TestSetup_HappyPath_ExitsZero                   // unattended config, all consented, exits 0
TestSetup_PrereqsDrift_Acknowledged_ExitsZero   // drift found, config says continue → exit 0
TestSetup_PrereqsDrift_Rejected_ExitsTwo        // drift found, config says don't continue → exit 2
TestSetup_QuitAtPrompt_ExitsOneThirty           // unattended config sets welcome.consent=false → exit 130
TestSetup_ConfigMissing_ExitsOne                // --config points at nonexistent file
TestSetup_WritesGitIdentityToWorkspace          // verifies the per-folder git config write
TestSetup_JournalRecordsSession                 // verifies journal entries written for session_start/end + identity_set
```

Plus integration tests for each new package (prompt, journal, identity, wizard). Targets:
- `internal/prompt/prompt_test.go`: stdin parsing edge cases (empty, default, validation retries)
- `internal/journal/journal_test.go`: append-with-crash-simulation, iterate, session boundaries
- `internal/identity/identity_test.go`: git config write semantics (`git config --local`)
- `internal/wizard/wizard_test.go`: step orchestration with stub steps

## 9. Deferred from alpha.2 to subsequent specs

- **alpha.3:** `repair` (install missing tools per manifest), `--ForceUnlock`, session lock for setup+repair concurrency.
- **alpha.4:** `undo --target` + `--all` (reverses any journaled action), journal compaction.
- **alpha.5:** Folder taxonomy port — `manifest/folders.yaml`, step 4 (`Pick workspace location`), step 5 (`Create folders`).
- **alpha.6:** Repo cloning — `manifest/repos.yaml`, step 6, GH auth via `repair`.
- **alpha.7:** VS Code workspace + `.vscode/` defaults.
- **beta.1:** `self-update`, Homebrew tap, winget manifest, all the `--json` output flags.
- **v2.0.0 final:** Code signing, notarization, parity check vs `legacy/v1.9.0`.

## 10. Acceptance criteria for alpha.2

The release is ready to tag `v2.0.0-alpha.2` when:

1. All ~7 acceptance tests from §8 exist, are failing pre-implementation, then pass post-implementation.
2. `go test ./...` clean on all 3 host OSes (when CI is re-enabled).
3. `go test -tags acceptance ./tests/acceptance/...` reports all alpha.1 + alpha.2 tests pass.
4. Manual smoke on a real machine: `ca-bootstrap setup` runs all 3 steps interactively without freezing or producing mojibake'd output. (The exact bug class from `feedback_ca_bootstrap_recurring_stdio_bugs.md` — we will verify by smoke test, not just unit tests.)
5. AB# (filed before any code lands) is in state `Active` or `In Progress`.
6. README.md gains a `setup` section.
7. The collaboration HTML's status pills evolve: alpha.1 → DONE, alpha.2 → IN PROGRESS / DONE.

## 11. References

- alpha.1 spec: [`docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`](2026-05-25-go-v2-0-alpha-1-spec.md)
- alpha.1 plan: [`docs/plans/2026-05-25-go-alpha-1-plan.md`](../plans/2026-05-25-go-alpha-1-plan.md)
- Pivot doc: [`docs/specs/2026-05-25-go-rewrite-pivot.md`](2026-05-25-go-rewrite-pivot.md)
- Tutorial doc (alpha.1 chapters 1-11): [`docs/tutorials/tdd-walkthrough.md`](../tutorials/tdd-walkthrough.md)
- Recurring stdio bug pattern (the reason we picked the prompt model in §2.B-2): `~/.claude/projects/.../memory/feedback_ca_bootstrap_recurring_stdio_bugs.md`
