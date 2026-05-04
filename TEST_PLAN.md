# ca-bootstrap test plan

> **Status: draft, pending review.** Once approved, the work in §6 lands as part of v1.1.0.

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

Each fixed bug gets one test, named for the version that introduced or fixed it:

- `regression-v1.0.1-wsl-blocks.itests.ps1` — mock `wsl` to record args; assert step 80's command includes `--no-launch`
- `regression-v1.0.2-windows-gitconfig-escape.itests.ps1` — Windows-only; runs step 70; asserts `git config --list --global` exits 0 after setup
- `regression-v1.0.2-cache-recovery.itests.ps1` — assert bootstrap.ps1 self-heals when the cache git operation fails

Each test's docstring explains what version it regresses, with a link to the commit and release notes.

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

1. **Layer 5 first** — the regression tests for v1.0.0–v1.0.2. These are the most concrete: each one reproduces a specific bug. Writing them first proves the test infrastructure works and prevents the exact recurrence.
2. **Layer 3** — wizard subprocess. Highest leverage since it touches the most surfaces.
3. **Layer 2** — step integration. Fills in the gaps Layer 3 misses (per-step Undo).
4. **Layer 4** — bootstrap script. Smaller surface but catches real bugs.
5. **Layer 1 expansion** — last because it's the smallest leverage; only adds value where Layer 2/3 can't reach.

Estimated effort: ~3 days. Single commit per layer for bisectable history.

## 9. Acceptance criteria

The suite is "good enough" when, simulating each fixed-bug scenario, the suite fails on the buggy code and passes on the fixed code. Specifically:

- Revert `f4c1d70` (the v1.0.2 includeIf forward-slash fix) and run the regression suite on Windows → must report a failure.
- Revert `363553a` (the v1.0.1 `--no-launch` fix) and run the regression suite → must report a failure.
- Revert `d40dea1` (the v1.0.2 cache-recovery fix) → must report a failure.

If any of those three reverts still passes the suite, the test plan needs more work.

## 10. Open questions for review

1. Is wizard subprocess testing on Windows runners reliable enough? GitHub Actions Windows runners have known flakiness with subprocess spawning.
2. Should we add a `make test:integration` target that runs Layers 2-5 locally, or keep them CI-only to avoid local environment pollution?
3. The current smoke fixture (`tests/fixtures/smoke-answers.txt`) is fragile — it depends on the host having or not having tools. Should we delete it in favour of YAML-driven Layer-3 tests?
4. Do we need a Layer-3 test that boots into a clean Docker container to exercise "fresh-OS" install flow? Probably not for v1.1.0; possibly for v2.0.0.

---

*End of plan. Review feedback welcome before implementation begins.*
