# ca-bootstrap test plan

> **Status: revised after independent review (see §11). Ready to implement.** Lands as v1.1.0.

## 1. Why this plan exists

v1.0.0 → v1.0.2 shipped three patch releases for bugs the existing test suite couldn't catch:

| Bug | Root cause | Existing tests said |
|---|---|---|
| `wsl --install` blocks the wizard | Process model: bash drops as a child of the parent pwsh; Windows-only behaviour | "All tests pass" — no integration test ever ran step 80 on Windows |
| `bad config line N in .gitconfig` | Path separator: Windows `\` is an escape character in git config values | "All tests pass" — no test ran `git config --list` after step 70 |
| Cache update fails silently | The bootstrap's `git pull` exited non-zero but its return value was ignored, so the user ran stale code | "All tests pass" — no test exercised the bootstrap-script-as-a-whole |

The common thread: **the unit tests cover library helpers in isolation, but no test ever runs the wizard end-to-end against a real shell on a real OS.** Every bug above lives in the seam where the wizard hands off to a real subsystem (git, wsl, gh, the OS shell).

## 2. Coverage gaps

| Layer | Today | Gap |
|---|---|---|
| Unit | 16 Pester tests over `lib/journal.ps1`, `lib/tools.ps1`, `lib/answers.ps1` | No tests for path normalization, output-stream behaviour, prompt input parsing, install-dispatch decisions |
| Integration (in-process) | None | No test exercises a step's full Test → Invoke → Undo cycle |
| Integration (subprocess) | `doctor --json` smoke | No test runs `setup` end-to-end and asserts the resulting filesystem + global gitconfig + journal state |
| Cross-platform | CI matrix runs the unit tests on Win/Mac/Linux | But only the unit tests; the wizard itself is never exercised on Windows in CI |
| Regression | None per fixed bug | A v1.0.0-class regression today would ship again; we have no "this exact case must not regress" assertion |

## 3. Bug taxonomy and what would catch each

For each fixed-or-likely bug class, the test layer that catches it:

### 3.1 Path-separator handling
- **Class**: backslash in a context where forward-slash is required (or vice versa)
- **Bugs caught**: includeIf path; gitdir pattern; manifest-defined repo `into:` paths on Windows
- **Test layer**: integration on Windows runner. After setup, assert `git config --list --global` exits 0 (proves the gitconfig is parseable). After identity step, assert `git config -f $workspace/.gitconfig user.email` returns the expected email (proves the workspace .gitconfig is also parseable).

### 3.2 Output stream / pipeline behaviour
- **Class**: Write-Host vs Write-Output; pipeline auto-unwrap; `,$x` double-wrap
- **Bugs caught**: `doctor --json` empty when captured into `$output`; `Get-CABJournalEntries` returning empty hashtables when called from inside a function
- **Test layer**: subprocess integration. Run `pwsh ./ca-bootstrap.ps1 doctor --json | jq -e .checks`, assert exit 0 and length > 0. Repeat for every command that has a non-default output mode.

### 3.3 Process model differences
- **Class**: subprocess that drops into an interactive shell or otherwise blocks the parent
- **Bugs caught**: `wsl --install` (without `--no-launch`); any `gh auth login` flow that opens a browser without `--web`
- **Test layer**: integration with timeout. Each subprocess invocation must complete within N seconds; if it hangs, the test fails. WSL test runs with a stub binary that simulates `wsl --install` without actually installing.

### 3.4 PowerShell type coercion
- **Class**: `$true -eq 'quit'` returns true; `[ordered]` vs `[hashtable]`; numeric coercion in array contexts
- **Bugs caught**: welcome step's confirm logic; journal entry copy via Generic.List<hashtable>
- **Test layer**: unit tests. Specific assertions for each known coercion gotcha. Add a "PowerShell foot-guns" suite that documents what we've hit and asserts the workaround still works.

### 3.5 State persistence and idempotency
- **Class**: re-running setup duplicates work; transcript file held open prevents AfterEach cleanup; journal accumulates entries that drift from disk
- **Bugs caught**: Pester Windows tests pre-fix; potential journal drift after manual file deletion
- **Test layer**: integration. Run setup, then setup again — assert second run records zero new clone/folder entries. Run setup, delete a repo manually, run doctor — assert drift detection. Run undo, then setup — assert clean rebuild.

### 3.6 Bootstrap-script behaviour
- **Class**: git pull on cache fails silently; pwsh install fails on a distro that needs MS repos first
- **Bugs caught**: v1.0.0 cache pinning when global .gitconfig was malformed
- **Test layer**: integration of the bootstrap layer itself. Use a hermetic `$CA_BOOTSTRAP_CACHE` that the test sets up with deliberately corrupted state, run the bootstrap entry point, assert it self-heals.

## 4. Proposed test layers

```
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 1 — Pester unit tests (already present, expand)               │
│   ./tests/lib/*.tests.ps1                                           │
│   In-process; no subprocess; no filesystem outside temp.            │
│   Targets: every lib/ helper, every step's Test function.           │
└─────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 2 — Step integration tests (NEW)                              │
│   ./tests/steps/*.itests.ps1                                        │
│   In-process; calls the step's Invoke and Undo functions against    │
│   a real (but hermetic) workspace under [System.IO.Path]::GetTempPath│
│   Targets: every step end to end, mocking only network calls.       │
└─────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 3 — Wizard subprocess tests (NEW)                             │
│   ./tests/wizard/*.itests.ps1                                       │
│   Spawns `pwsh ./ca-bootstrap.ps1 ...` as a child, asserts the      │
│   resulting on-disk state + exit code. Catches stream-handling and  │
│   parameter-binding bugs that Layer 2 misses.                       │
│   Mode: -Unattended -ConfigFile, prerequisites.install_missing: false│
└─────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 4 — Bootstrap-script integration tests (NEW)                  │
│   ./tests/bootstrap/*.itests.ps1 + .sh                              │
│   Runs bootstrap.ps1 / bootstrap.sh themselves with a stubbed       │
│   $REPO_URL pointing at a fixture repo on the local filesystem.     │
│   Catches cache-update / corrupt-config-recovery bugs.              │
└─────────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────────┐
│ Layer 5 — Regression tests (NEW)                                    │
│   ./tests/regression/v1.0.x.itests.ps1                              │
│   Each previously fixed bug gets one explicit test that fails on    │
│   the regression and passes on the fix. Documents *why* the test    │
│   exists so future contributors don't delete it.                    │
└─────────────────────────────────────────────────────────────────────┘
```

## 5. Concrete test cases

### 5.1 New unit tests (Layer 1)

**`tests/lib/path-norm.tests.ps1`** — new file
- `ConvertTo-CABGitdirPattern` produces forward slashes on every OS
- Workspace .gitconfig path written by step 70 contains no `\` after normalization
- Pester runs on Windows, macOS, Linux as part of the matrix

**`tests/lib/output-streams.tests.ps1`** — new file
- `Write-CABColor` honours `$env:NO_COLOR`
- `Read-CABConfirm` returns the right type for each input: 'y' → `[bool]$true`; 'n' → `[bool]$false`; 'q' → `[string]'quit'`; '' → `$Default`
- `Read-CABChoice` matches case-insensitively
- `Get-CABJournalEntries` returns hashtables whose `.path` property is non-empty after a round-trip through ConvertTo-Yaml + ConvertFrom-Yaml

**`tests/lib/tools-dispatch.tests.ps1`** — new file
- `Get-CABInstallEntry` resolves the right entry for each OS family (mock `Get-CABOSFamily`)
- `Install-CABTool -Context @{ WhatIfMode = $true }` never actually runs the install command — verify by mocking `winget`/`brew`/`apt` and asserting they were not called

### 5.2 Step integration tests (Layer 2)

**`tests/steps/40-workspace.itests.ps1`** — new file
- BeforeEach: create a temp dir, point CA_BOOTSTRAP_WORKSPACE at it
- Test: workspace is created with the right path
- Test: re-running Invoke is idempotent (no second journal entry)
- AfterEach: remove the temp dir

**`tests/steps/50-folders.itests.ps1`** — new file
- All four folders created from manifest/folders.yaml
- Re-run: zero new journal entries
- Manually delete one folder, re-run: only that folder is recreated

**`tests/steps/70-git-identity.itests.ps1`** — new file (CRITICAL — catches the v1.0.2 bug)
- After Invoke, run `git config --list --global --file <fake-global-gitconfig>` and assert exit 0
- Assert the includeIf path uses forward slashes regardless of OS
- Assert `git config -f <workspace>/.gitconfig user.email` returns the expected email
- Run Undo, assert the includeIf block is gone and the workspace .gitconfig is removed
- Test on Windows (path with spaces): `C:\Users\Test User\ChannelAssistDev\` should round-trip cleanly

**`tests/steps/80-extras.itests.ps1`** — new file
- VS Code workspace file is valid JSON listing all cloned repo dirs
- WSL install command line includes `--no-launch` (mock `wsl` binary, capture args, assert)

### 5.3 Wizard subprocess tests (Layer 3)

**`tests/wizard/setup.itests.ps1`** — new file
- Hermetic answers.yaml: workspace = temp; install_missing = false; clone groups = none; configure_git_identity = true; extras: only vscode_workspace_file = true
- Spawn `pwsh ./ca-bootstrap.ps1 setup -Unattended -ConfigFile <path>`
- Assert exit code = 0
- Assert journal.yaml exists, parses, has one session with expected actions
- Assert workspace exists with all four folders
- Assert global .gitconfig is parseable (`git config --list -f <fake-home>/.gitconfig` exit 0)
- Assert workspace `.gitconfig` exists with [user] block

**`tests/wizard/doctor.itests.ps1`** — new file
- `pwsh ./ca-bootstrap.ps1 doctor` exit code matches presence/absence of issues
- `pwsh ./ca-bootstrap.ps1 doctor -Json | ConvertFrom-Json` produces a payload with `.checks` and `.schema_version`
- Assert no extra non-JSON output on stdout in `-Json` mode

**`tests/wizard/repair-undo.itests.ps1`** — new file
- Run setup, delete a folder, run repair --target folders, assert folder is back
- Run setup, run undo --force, assert workspace gone, assert global gitconfig has no leftover includeIf

### 5.4 Bootstrap-script tests (Layer 4)

**`tests/bootstrap/cache-recovery.tests.ps1`** — new file
- Set up a fixture cache dir whose `.git` is intentionally corrupted
- Run bootstrap.ps1 with $REPO_URL pointed at a local-fs fixture clone
- Assert the script detects the corruption, re-clones, and proceeds
- Same test in `tests/bootstrap/cache-recovery.itests.sh` for bootstrap.sh

**`tests/bootstrap/bad-gitconfig.tests.ps1`** — new file (CRITICAL — catches the v1.0.2 bug)
- Set up a fake $HOME with a malformed ~/.gitconfig (line: `path = C:\Users\foo\bar`)
- Run bootstrap.ps1, assert it self-heals (notices the bad config, refreshes cache, completes)

### 5.5 Regression tests (Layer 5)

Each fixed bug gets at least one test that asserts the **property the fix preserves**, not just the spelling of the fix. Named for the version that fixed it. Each test's docstring links to the fix commit.

**v1.0.1: wsl --install blocks the wizard** (commit `363553a`)
- `regression-v1.0.1-wsl-blocks-property.itests.ps1` — **load-bearing**: spawn the wizard with a `wsl` stub on PATH that simulates the original blocking behaviour (reads from stdin and waits 30 s). Assert the wizard exits within 5 s. This catches the bug regardless of which mechanism the fix uses.
- `regression-v1.0.1-wsl-no-launch-flag.itests.ps1` — auxiliary: assert step 80's command line includes `--no-launch`. Documents the current implementation choice but doesn't lock it in.

**v1.0.2: Windows backslash in git config value** (commit `d40dea1`, `steps/70-git-identity.ps1` hunk)
- `regression-v1.0.2-gitconfig-backslash-grep.itests.ps1` — runs on **every OS** (the bug is OS-conditional but the test isn't). After step 70, grep both `~/.gitconfig` and `<workspace>/.gitconfig` for backslashes in any line starting with `path =` or `[includeIf "gitdir:`. Assert zero matches. This catches the bug class even on macOS/Linux runners.
- `regression-v1.0.2-gitconfig-parseable.itests.ps1` — Windows-only: with `$env:USERPROFILE` pointed at a fixture HOME, run step 70, then run `git config --list --global` (no `-f`). Assert exit 0. This catches the user-visible failure mode (every subsequent git command erroring with "bad config line N").

**v1.0.2: cache-update fails silently on bad gitconfig** (commit `d40dea1`, `bootstrap.ps1`/`bootstrap.sh` hunks)
- `regression-v1.0.2-cache-recovery.itests.ps1` — set up a fixture cache dir, point `$REPO_URL` at a local-fs fixture clone, deliberately corrupt the cache, run `bootstrap.ps1`, assert it self-heals (clones fresh) AND completes setup.
- `regression-v1.0.2-bootstrap-no-silent-failure.itests.ps1` — **load-bearing**: stub `git` (PATH override) with a wrapper that always exits 1. Run `bootstrap.ps1`, assert exit code is non-zero AND stderr contains a recognizable diagnostic message. This catches the original failure pattern (silently ignoring a non-zero exit) regardless of how the recovery is implemented.
- `regression-v1.0.2-end-to-end.itests.ps1` — set up a fake `~/.gitconfig` with a malformed `path = C:\foo\bar` line, point `$HOME` (or `$env:USERPROFILE`) at a fixture, run `bootstrap.ps1` end-to-end. Assert it self-heals and completes setup. **This is the highest-value regression test in the suite** because it covers the realistic chain (bug 2 produces the conditions that trigger bug 3) the user actually hit.

**v1.0.3: workspace path leaks relative** (commit `e83e9cc`)
- `regression-v1.0.3-relative-workspace-rejected.itests.ps1` — set `$env:USERPROFILE` to `.` (or to an empty string), run step 40 standalone. Assert it fails with status `fail` and a message containing "Refusing to proceed". Asserts `$Context.WorkspacePath` is **never** assigned anything non-rooted.
- `regression-v1.0.3-clones-only-absolute.itests.ps1` — set `$Context.WorkspacePath` to a relative-looking path (`./bogus`) and call step 60's Invoke directly. Assert no clone is attempted; status is `fail`.

## 6. CI matrix expansion

The current `.github/workflows/ci.yml` runs:
- `pester` (unit) on Win/Mac/Linux
- `doctor --json` smoke on Win/Mac/Linux
- `shellcheck` on Linux

Add:
- `step-integration` (Layer 2) on Win/Mac/Linux — new job, runs Pester against `tests/steps/`
- `wizard-integration` (Layer 3) on Win/Mac/Linux — new job, spawns subprocess, checks state
- `bootstrap-integration` (Layer 4) on Win/Mac/Linux — new job
- `regression` (Layer 5) on Win/Mac/Linux — new job

All five test jobs run in parallel via the matrix; total wall time ≈ longest job.

## 7. Out of scope (explicitly)

These are deliberately not covered to keep the suite tractable:

- **Tool install behaviour against real package managers.** We mock the dispatch and assert the right command line is built; we don't actually run `winget install …` in CI because it's slow, flaky, and needs elevation.
- **gh auth login browser flow.** Out of scope; tests run with a pre-set `GH_TOKEN`.
- **Real Docker on macOS / WSL2 on Windows.** Tested manually before each release; the CI runners can't (or shouldn't) reboot.
- **Network failure modes for repo cloning.** Mocked at the `Invoke-CABRepoClone` boundary.
- **Localized Windows.** English locale only.

## 8. Implementation order

Reviewer correction (see §11, finding #14): "Layer 5 first" is the right intent but the wrong order. Several Layer 5 tests depend on subprocess plumbing that needs to exist before they can be written. Revised order:

1. **Test-mode seam in source code** — add `$env:CA_BOOTSTRAP_TEST_MODE` and related env-var hooks to the orchestrator. See §8.1 below for the contract. Without this, Layer 3 hangs on real `gh auth login` browser flows and `winget install` prompts in CI.
2. **Layer 1 expansion** for the path-normalization grep test — single-process, no plumbing needed; immediately catches the v1.0.2 backslash bug class.
3. **Layer 4** — bootstrap-script tests (smallest surface, clear inputs, no test-mode dependency since the bootstrap itself doesn't run the wizard).
4. **Layer 5 cache-recovery and gitconfig regression tests** — depend on Layer 4's fixture infrastructure plus the path-normalization tests from step 2.
5. **Layer 3** — wizard subprocess. Now buildable because the test-mode seam exists.
6. **Layer 5 wsl-blocking-property and workspace tests** — depend on Layer 3.
7. **Layer 2** — step integration. Fills gaps Layers 3/5 miss (per-step Undo, encoding edge cases).
8. **CI matrix expansion** (§6) — last; gates the remaining work behind green CI.

Single commit per layer for bisectable history. Estimated effort: ~3–4 days.

### 8.1 Test-mode seam contract

The orchestrator and steps must respect these env vars when set:

| Env var | Effect |
|---|---|
| `CA_BOOTSTRAP_TEST_MODE=1` | Master switch: enables all of the below. Banner adds a "TEST MODE" warning. |
| `CA_BOOTSTRAP_TEST_GH_USER` | Step 30 returns this username as if `gh auth status` succeeded; never invokes `gh auth login`. |
| `CA_BOOTSTRAP_TEST_TOOLS_OK` | Comma-separated list of tool ids treated as ok in step 20 without running `check.cmd`. |
| `CA_BOOTSTRAP_TEST_REPOS_FILE` | Path to a fixture repos.yaml whose entries use `file://` URLs pointing at a local-fs git repo. Step 60 substitutes `gh repo clone` with `git clone` when the URL is `file://`. |
| `CA_BOOTSTRAP_TEST_NO_INSTALL=1` | Step 20's Invoke is a no-op even when called directly. |
| `CA_BOOTSTRAP_TEST_WSL_STUB` | Path to a stub `wsl` executable to put first on PATH for step 80 testing. |

Document the seam in `docs/testing.md` (NEW). All seam env vars are explicitly tested for in the orchestrator and pass through `$Context` so steps see them. The seam is intentionally not exposed via the CLI to keep the surface small.

## 9. Acceptance criteria

Two-level acceptance: the suite must catch (a) **regressions of bugs we already saw** and (b) **regressions of the bug-class** even if the implementation changes shape.

### 9.1 Point regressions

For each fixed-bug commit, scalpel-revert just the relevant hunk and run the suite. The named regression test must fail.

- Revert `steps/70-git-identity.ps1` hunk in `d40dea1` (gitconfig backslash fix) → `regression-v1.0.2-gitconfig-backslash-grep.itests.ps1` must fail on every OS; `regression-v1.0.2-gitconfig-parseable.itests.ps1` must fail on Windows.
- Revert `bootstrap.ps1`/`bootstrap.sh` hunks in `d40dea1` (cache recovery) → `regression-v1.0.2-cache-recovery.itests.ps1` AND `regression-v1.0.2-bootstrap-no-silent-failure.itests.ps1` must fail; `regression-v1.0.2-end-to-end.itests.ps1` must fail.
- Revert `363553a` (`--no-launch` fix) → `regression-v1.0.1-wsl-blocks-property.itests.ps1` must fail (timeout); `regression-v1.0.1-wsl-no-launch-flag.itests.ps1` must fail (flag missing).
- Revert `e83e9cc` (workspace absolute-path fix) → `regression-v1.0.3-relative-workspace-rejected.itests.ps1` must fail.

> **Note:** the original draft of this plan named `f4c1d70` (a docs-only commit) instead of `d40dea1` for the gitconfig fix. Reviewer caught it; SHA list above corrected.

### 9.2 Class-level coverage

Class-level tests must catch a future bug *of the same shape* without naming the fix's mechanism:

- **Path normalization class**: inject a deliberate `\` into a config value on a feature branch (e.g. modify step 70 to use the un-normalized path). The grep-for-backslash regression test must fail. (Tests the property; resilient to refactors.)
- **Output stream class**: inject a `Write-Host` (instead of `Write-Output`) into doctor's JSON path. The doctor `--json | jq -e .checks` test must fail.
- **Process model class**: add a stubbed sleep-on-stdin subprocess to any step. The wizard-timeout test must fail.
- **Silent-failure class**: insert a `2>$null | Out-Null` around any non-fatal-but-recoverable command. The "no silent failure" tests must catch it.

These class-level tests are documented as such in their docstrings so future contributors don't delete them as "redundant with the point regression."

## 10. Resolved questions

1. **Wizard subprocess testing on Windows runners** — reliable enough; the real flakiness sources are real-tool side effects (winget/gh prompts, missing TTY), not subprocess plumbing. Mitigation is the test-mode seam from §8.1.
2. **`make test:integration`** — yes, add a local target. Layers 2/4 are pure-Pester so safe locally; Layers 3/5 default to a temp HOME under `[System.IO.Path]::GetTempPath()`/`cab-test-$(Get-Random)` to avoid polluting the developer's real environment. The Makefile target sets `$env:HOME` (and `$env:USERPROFILE` on Windows) to the temp dir for the duration of the run.
3. **Smoke fixture** — delete. The positional-stdin fixture is fragile and obsoleted by Layer 3 + the test-mode seam. Migrate any unique scenarios into named YAML fixtures under `tests/fixtures/answers/`.
4. **Docker-container fresh-OS testing** — out of scope for v1.1.0; reconsider for v1.2.0 alongside containerized integration runners.

## 11. Independent review summary

A pre-build review was conducted on this plan. Key changes that landed in this revision:

- **§9 SHAs corrected.** Original cited `f4c1d70` (a docs-only commit) for the gitconfig fix; the actual fix is in `d40dea1` alongside the cache-recovery fix. The two fixes share a commit, so the acceptance criteria now scalpel-revert per-file rather than per-commit.
- **WSL regression test re-shaped.** The original "assert `--no-launch` is in the args" test only catches the spelling of the fix. Replaced with a load-bearing timeout-based test that catches the *property* (wizard exits within 5 s) regardless of mechanism. Kept the flag-presence test as auxiliary.
- **Gitconfig regression tests now run on every OS.** A grep-for-backslash test is OS-independent and catches the bug class even on macOS/Linux runners. The Windows-specific `git config --list` test is kept as a complement.
- **Cache-recovery tests now bracket the original failure mode.** Added a "doesn't silently continue on failure" test that stubs `git` to always exit 1; combined with the self-heal test, the pair catches the bug class.
- **Test-mode seam added to §8.1.** Layer 3 isn't buildable without it. Listed as the first implementation step.
- **Implementation order revised.** Layer 5 first was the right intent but wrong order; revised so dependencies build up.
- **Class-level acceptance criteria added (§9.2).** Point regressions catch known bugs; class-level tests catch future bugs of the same shape.

Findings the reviewer raised that are accepted but tracked for v1.2.0 rather than v1.1.0:

- Concurrency / re-entrancy testing (would also require implementing a journal lockfile)
- Sensitive-data hygiene (token redaction in journal/transcript)
- Locale / encoding (UTF-8 in identity name; Windows codepage interactions)
- Path-with-spaces / non-ASCII parameterization
- Manifest-regex sanity job (catches version_regex drift when a tool changes its `--version` output)
- Refactor `Read-CABConfirm` to return a single-typed result instead of `[bool] | [string]`

These are listed in `TEST_PLAN_v1.2.md` (placeholder).

---

*End of plan. Implementation begins.*
