# ca-bootstrap Go-rewrite pivot

- **Date:** 2026-05-25
- **Author:** Peter Giannopoulos (decision); drafted with Claude Code (AI-assisted)
- **Status:** Decided. Archival tag `legacy/v1.9.0` created + pushed. Spec/implementation phases underway (alpha.1–alpha.3).
- **Work item:** [AB#40028](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/40028) — child of Epic [AB#38056](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/38056) (AI Platform & Workflow Integration — 2026)
- **Related ADRs:** TBD (a new ADR formalizing the rewrite + distribution model should follow this doc)
- **Supersedes:** `DESIGN.md` § 16 (PowerShell-era distribution + one-liner stability assumptions)
- **Archival tag:** `legacy/v1.9.0` — points at the final PowerShell-era commit (pinned to `008b2e2`, dev HEAD as of this date)

## 1. TL;DR

The PowerShell implementation of `ca-bootstrap` is being **archived**, not patched, and replaced by a **Go CLI distributed as pre-built static binaries via GitHub Releases** (one binary per OS/arch). The current iteration is tagged for archival reference. No new feature work or non-critical bug fixes will land on the PowerShell codebase. Subsequent work follows a strict order: **spec → tests → code**. No code lands before its acceptance tests exist.

## 2. Why we're pivoting

### 2.1 Trigger: three independent bugs in one 90-minute session (2026-05-25)

In a single session attempting normal first-use paths from a Windows machine:

1. **The documented Windows install one-liner (`iwr ... | iex`) has never worked** against `bootstrap.ps1` in its current form. The script declares `#requires` + `[CmdletBinding()]` + `param()`, all of which are script-file-only constructs that `Invoke-Expression` cannot parse. Three workarounds were attempted (raw `iex`, `scriptblock::Create`, function-wrap); all failed for the same structural reason. The fourth (tempfile + `& $t`) works but defeats the "one-liner" UX promise.
2. **`make` on Windows produces literal `\033[...]` escape sequences instead of ANSI colors, and mojibake'd box-drawing characters** (UTF-8 bytes interpreted as CP-1252). The Windows-native `./make.ps1` peer (added in PR #68 specifically to escape this class of problem) presented a separate failure mode.
3. **`./make.ps1 setup` freezes.** Cursor sitting, no visible output, 30s–2min wait. Symptom is consistent with `Read-Host` prompts emitted by a child `pwsh` process whose stdout/console state is not properly visible to the parent shell — a recurring failure mode in this codebase.

None of these are isolated. They are symptoms of the same structural mismatch (§ 2.2).

### 2.2 The recurring class

Six prior commits, across the project's history, addressed bugs in the same class:

| Commit | Symptom that was "fixed" |
|---|---|
| `11648b7` (#30) | bootstrap `curl \| bash` stdin-at-EOF freeze |
| `87cd063` (#15) | TUI prompt question wrap freeze |
| `4cc6db1` (#13) | TUI `Write-Host` routing, step body, prompt context, quit-exit |
| `f1b7cc9` (#7)  | TUI Textual stdio not routed to `/dev/tty` in `--rpc` mode |
| `38bab2b`       | test-harness stubs stalled on stdin/stdout |
| `bec1534` (#17) | **dropped the TUI entirely** to escape the class |

PR #17 was explicitly intended to make this class of bug go away by removing the TUI surface and committing to CLI-only flows. Yet the 2026-05-25 session surfaced the same symptoms in plain CLI mode. **Each fix is real; the class persists.** That is the signal.

### 2.3 Structural diagnosis

PowerShell's interactive-console model is structurally mismatched with the cross-platform bootstrap use case:

- **Two-runtime split** (Windows PowerShell 5.1 vs PowerShell 7+) forces every script to either reject 5.1 (alienating fresh Windows boxes) or compatibility-target it (constraining the language). `bootstrap.ps1` chose 7+ via `#requires`, which is the root of the install-one-liner failure in § 2.1.1.
- **Execution policy** (Restricted by default on Windows) blocks file-based script execution, forcing curl-pipe patterns through `iex`, which then fails on any non-trivial script (`#requires`, `[CmdletBinding()]`, `param()` are all invalid in expression context).
- **Console code-page** defaults to CP-437/1252 on Windows; UTF-8 emission requires explicit setup that not every entry point performs.
- **ANSI sequence handling** is inconsistent across consoles (Windows Terminal vs `conhost.exe` vs ISE vs VS Code integrated terminal). Color codes that work in one fail in another.
- **Child-process stdio** inheritance is fragile: `& pwsh -File child.ps1` from a parent pwsh can yield invisible `Read-Host` prompts, late-flushing stdout, or PSReadLine state confusion.
- **No static linking.** Every machine the script touches must have the right pwsh version, the right execution policy, the right console settings, the right encoding.

Each of these can be worked around individually. The cost of working around all of them in a tool whose entire job is "make a fresh laptop usable" is greater than the cost of rewriting in a runtime that has none of these problems.

### 2.4 Loss of confidence

Quoting Peter, 2026-05-25: "I have no confidence AT ALL in this codebase and I think it's become horribly complex."

The codebase is not bad — it is correct PowerShell. It is the *abstraction choice* that has failed. Continuing to patch it would produce a 7th, 8th, 9th fix in the same class.

## 3. What we're keeping (forward-compatible concepts)

These design ideas have proven their value and should be preserved in the Go rewrite — possibly with refinements:

- **Command surface:** `setup` / `doctor` / `repair` / `undo` — a four-verb CLI is a strong, intuitive UX.
- **Action journal** (`lib/journal.ps1`): persistent record of side effects, enabling `undo` to be safe and idempotent. This concept should carry over essentially intact — only the storage format may change.
- **Manifest-driven tools** (`manifest/tools.yaml`): declarative source of truth for what gets installed, at which versions, on which platforms. The schema is sound; the format (YAML) is fine.
- **Folder taxonomy** (`ca-*` workspace layout, `manifest/folders.yaml`, README templates): recent work (PR #74, 2026-05-22). The taxonomy and the renamed_from chain logic should carry over.
- **Doctor / repair separability:** `doctor` is read-only; `repair` is targeted-or-full. This split has held up under usage.
- **Interactive-by-default with `-Unattended` + `-ConfigFile` escape hatch:** correct UX for the audience (developers).

## 4. What we're dropping

- **PowerShell as the implementation language.** All `.ps1` files at the root and under `lib/`, `commands/`, `steps/`, `scripts/` become reference material only.
- **The `Makefile` + `make.ps1` decision tree.** A static binary needs no task runner shim.
- **The `bootstrap.ps1` / `bootstrap.sh` curl-pipe entry points.** Replaced by "download the binary from GitHub Releases."
- **The TUI surface** — already dropped in PR #17; staying dropped. The Go rewrite will be plain CLI with stdlib-quality progress reporting (`spf13/cobra` + minimal status output). No `bubbletea` unless the spec phase explicitly justifies it.
- **`#requires`, `[CmdletBinding()]`, `param()`, `Set-ExecutionPolicy`, `iwr`, `iex`, `Invoke-RestMethod`, child-`pwsh` dispatch.** All gone.
- **Embedded Python dependencies** (cab-tui was already removed in #17; staying removed).

## 5. How: rewrite approach

### 5.1 Language: Go

Rationale:
- **Single static binary** per platform — exactly the distribution model required.
- **Strong cross-compilation** — `GOOS=windows GOARCH=amd64 go build` etc. produces native binaries from any host. CI matrix becomes trivial.
- **First-class `testing` package** — TDD-friendly, no framework dance.
- **Mature ecosystem for CLI tooling:** `cobra` (command parsing), `viper` (config), `survey` (prompts), `pterm`/`lipgloss` (output), `term` (terminal detection).
- **No runtime to install on the user's machine** — `pwsh 7+ required` becomes obsolete.
- **Strong stdlib for the actual operations bootstrap needs:** `os/exec`, `archive/zip`, `net/http`, `encoding/json`, `gopkg.in/yaml.v3`. Almost no transitive dependencies needed.

### 5.2 Distribution: GitHub Releases per platform

Targets for v0.1:
- `windows/amd64` (primary — the platform that has historically suffered most)
- `darwin/arm64` (Apple Silicon — primary dev platform)
- `darwin/amd64` (Intel Macs — secondary)
- `linux/amd64` (CI hosts, WSL2 inside Windows)

Each release publishes a checksum manifest (`SHA256SUMS`) and (eventually) a signed manifest (`SHA256SUMS.sig`). Open question: code signing for Windows SmartScreen + macOS notarization — addressed in spec phase.

Install becomes:
- **Manual:** Download → unzip → put on PATH → run.
- **Scripted (later, optional):** A *tiny* one-liner that just downloads + extracts + invokes — the kind of script that can be 5 lines, has no `#requires` headache, and can be paste-safely consumed via `iex`/`bash -c`. Crucially, this one-liner is **not** the binary; it's just a thin downloader. The binary itself has no parsing requirements.

### 5.3 Process: spec → tests → code (strict order)

> "Full spec-redesign, TDD first. No code before design and tests." — Peter, 2026-05-25

#### Phase A — Spec (in progress)

- This pivot doc is the *decision* record, not the spec.
- The spec will be a separate document — `docs/specs/<date>-go-rewrite-v0-1-spec.md` — that resolves the open questions in § 7.
- Spec must cover at minimum: command surface, prompt model, action-journal storage, manifest schema (forward-port or revise?), update mechanism, signing, telemetry policy, error model, exit codes, logging.
- Spec is locked when Peter approves the doc + accompanying ADR.

#### Phase B — Tests

- Acceptance tests written **first**, against the locked spec, in Go's `testing` package.
- Tests must exist for the v0.1 surface before any non-test code is committed.
- Use `t.TempDir()`, fixture manifests, and a fake-filesystem layer for unit tests; use real-binary execution in `_test.go` integration tests gated by a build tag.

#### Phase C — Implementation

- Code lands incrementally, each commit driven by making a failing test pass.
- v0.1 ships when the v0.1 acceptance tests all pass on Windows, macOS, and Linux in CI.

### 5.4 Repository layout (proposed; confirmed in spec phase)

Option A: rewrite-in-place. Keep this repo (`ChannelAssist/ca-bootstrap`), move PowerShell tree under `legacy/`, develop Go tree at the root. Pro: existing issues/PRs/wiki/CI continue to work. Con: messy git history.

Option B: new repo (`ChannelAssist/ca-bootstrap-go` or rename ca-bootstrap → ca-bootstrap-legacy and create a fresh ca-bootstrap). Pro: clean slate. Con: redirection / discoverability overhead.

**Recommendation:** Option A. The user-facing repo name doesn't change; users searching the org for "ca-bootstrap" find the active project. The PS lineage is preserved on the archival tag and the `legacy/` subtree.

### 5.5 Transition / lame-duck period

- The PowerShell `ca-bootstrap` remains usable for users who already have it cloned. It is **not** being deleted — only declared frozen.
- The README banner (added in this PR) signals "look at the Go rewrite" to anyone landing fresh on the repo.
- No new features. Critical user-blocker bugs *may* be fixed minimally, with the fix noted as "one more datapoint for the rewrite."
- v1.x patch releases are not anticipated. The archival tag is the canonical "last PS version."

## 6. Phases & deliverables

| Phase | Deliverable | Acceptance |
|---|---|---|
| **0** Pivot decision (this doc) | `docs/specs/2026-05-25-go-rewrite-pivot.md`, README banner, CHANGELOG entry, archival tag, Keystone journal entry | Peter approves + tag is pushed |
| **A** Spec | `docs/specs/<date>-go-rewrite-v0-1-spec.md` + ADR | Peter approves; all § 7 open questions resolved |
| **B** Tests | Failing acceptance test suite for v0.1 surface | Tests run; all fail with clear "not implemented" errors; CI matrix green for `go test ./...` (which runs and reports failures, not panics) |
| **C** v0.1 implementation | Minimal CLI implementing `setup` + `doctor` on Windows/macOS/Linux | Phase-B tests pass on CI matrix |
| **D** v0.2 | `repair` + `undo` | Phase-B tests for those verbs pass |
| **E** v1.0 | Feature parity with last PS version: tools manifest, folder taxonomy, action journal, identity config | Manual QA on a fresh Windows laptop succeeds end-to-end without intervention |

## 7. Open questions (resolved during spec phase)

1. **Binary name?** `ca-bootstrap` (mirrors current), `cab` (short), `cab-cli`, or other?
2. **Repository layout** — confirm Option A (in-place rewrite, PS tree → `legacy/`)?
3. **Manifest format** — keep YAML, switch to TOML (Go ecosystem prefers it), or JSON?
4. **Action journal format** — keep current JSON-lines, or revisit?
5. **Update mechanism** — built-in self-update, Homebrew tap, winget manifest, or pure-manual?
6. **Telemetry** — none, opt-in, or opt-in-with-clear-value-prop?
7. **Code signing** — Windows Authenticode (need a cert), macOS notarization (Apple Developer ID), or accept the SmartScreen / Gatekeeper warning for v0.1?
8. **TUI library** — pure stdlib + minimal status output (recommended given history), or `bubbletea` / `pterm`?
9. **CI matrix** — GitHub Actions native runners only, or include self-hosted for arm64 Linux?
10. **Versioning** — restart at `v0.1.0`, or continue the existing PS semver (`v2.0.0`)? Open question: do users perceive the rewrite as a breaking change of the same tool (→ major bump) or as a successor tool (→ fresh version line)?

## 8. References

- `docs/specs/2026-05-22-folder-taxonomy-design.md` — most recent PS-era design doc (taxonomy carries forward)
- Engineering journal entry (Keystone repo, 2026-Q2): to be written via `/journal` skill
- Archival tag: `legacy/v1.9.0` at commit `008b2e2`

> The decision rationale and recurring-bug-pattern analysis that drove this pivot are also retained in the AI assistant's private cross-session memory; they are summarized in §§ 2.1–2.4 above so the repository is self-contained (no external/local paths required to understand the decision).
