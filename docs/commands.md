# Command reference

ca-bootstrap is a multi-command CLI. Three equivalent entry points:

```bash
make <command>                                         # from a clone, friendliest
./ca-bootstrap.ps1 <command> [<targets>] [<flags>]     # direct invocation
./bootstrap.{ps1,sh} <command> [<targets>] [<flags>]   # forwards to ca-bootstrap.ps1
                                                        # when run from a clone;
                                                        # bootstraps the cache when
                                                        # piped from curl.
```

If `<command>` is omitted, `setup` runs.

### Make targets

| Target | Equivalent direct invocation |
|---|---|
| `make setup` | `pwsh ./ca-bootstrap.ps1 setup` (auto-launches the cab-tui front-end if it's installed) |
| `make setup-no-tui` | `pwsh ./ca-bootstrap.ps1 setup -NoTui` (force the legacy Read-Host CLI) |
| `make doctor` | `pwsh ./ca-bootstrap.ps1 doctor` (exits 0 even when drift is found, since drift is a valid output) |
| `make repos-drift` | `pwsh ./ca-bootstrap.ps1 repos-drift` (detect drift between manifest/repos.yaml and GitHub org; exits 0 even when drift is found) |
| `make repair ARGS='--all'` | `pwsh ./ca-bootstrap.ps1 repair -All` |
| `make repair ARGS='--target dotnet-10'` | `pwsh ./ca-bootstrap.ps1 repair -Target dotnet-10` |
| `make undo ARGS='--force'` | `pwsh ./ca-bootstrap.ps1 undo -Force` |
| `make tui-install` | Install the optional cab-tui Textual front-end into `cab-tui/.venv` (PEP 668-aware; clears macOS UF_HIDDEN on the editable `.pth`). |
| `make tui-test` | Run the cab-tui pytest suite. |
| `make test` | Full Pester suite (PowerShell side). |
| `make test-all` | Pester + cab-tui pytest together. |
| `make smoke` | End-to-end smoke test against a /tmp workspace. |
| `make wiki-clone` / `wiki-sync` / `wiki-push` / `wiki-update` | GitHub Wiki workflow — clone the wiki repo, mirror docs/ into it, push. `wiki-update` does sync + push. |
| `make release VERSION=X.Y.Z` | Full release: bump version, smoke + tests, commit, tag, push, GH release. |
| `make release-dry-run VERSION=X.Y.Z` | Same, no writes. |

---

## `setup` (default)

First-time onboarding wizard. Runs all eight steps in order. Each step detects existing state, prompts the user, and either acts or skips.

### Synopsis

```
./ca-bootstrap.ps1 [setup] [flags]
```

### Flags

| Flag | Effect |
|---|---|
| `-Unattended` | Non-interactive; reads decisions from `-ConfigFile`. |
| `-ConfigFile <path>` | YAML answers file. See `manifest/answers.example.yaml`. |
| `-WhatIf` | Dry-run; print what would happen, change nothing. |
| `-Verbose` | Stream every shell command to console. |
| `-LogPath <path>` | Override transcript location (default `~/.ca-bootstrap/last-run.log`). |

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | Success (or successful re-run that found nothing to do) |
| 10 | User quit |
| 2 | Required tool could not be installed |
| 3 | gh authentication failed |
| 4 | Workspace folder could not be created |
| 5 | One or more repos failed to clone |
| 6 | git identity or other config write failed |
| 99 | Unexpected error |

### Idempotent re-run

Running `setup` twice on the same machine is safe. The second run reads the action journal and skips work that's already been done. Useful when:

- A new repo has been added to the manifest since you last ran setup.
- A new tool has been added to `tools.yaml`.
- You want to top up a partial setup that was interrupted.

For a richer "verify my setup" experience, prefer `doctor`.

---

## `doctor`

Diagnostic-only. Runs every step's detection function but never modifies anything.

### Synopsis

```
./ca-bootstrap.ps1 doctor [flags]
```

### Flags

| Flag | Effect |
|---|---|
| `--json` | Output a structured JSON report (one object per check). |
| `--summary` | One-line-per-check terse output. |
| `--target <id>` | Check only one item (e.g. `--target dotnet-10`, `--target repos`, `--target identity`). |
| `--quiet` | Suppress all output except the exit code. |
| `-LogPath <path>` | Override transcript location. |

### Output formats

#### Default (human)

```
ca-bootstrap doctor — 2026-05-15 09:32

Workspace                    ✓  exists
Folder structure             ✓  4/4 folders present
Prerequisites
  git                        ✓  2.43.0
  ...
```

#### `--summary`

```
✓ workspace
✓ folders (4/4)
✓ git 2.43.0
⚠ node-20 v18.18.0 (older)
✗ cm-shared-libs missing
exit 2
```

#### `--json`

```json
{
  "schema_version": 1,
  "host": { "os": "windows", "user": "peter" },
  "checks": [
    { "id": "workspace", "status": "ok", "details": "exists" },
    { "id": "folders", "status": "ok", "details": "4/4 present" },
    { "id": "tool.git", "status": "ok", "version": "2.43.0" },
    { "id": "tool.node-20", "status": "warn", "found": "18.18.0", "required": "20" },
    { "id": "repo.cm-shared-libs", "status": "missing", "expected_path": "..." }
  ],
  "exit_code": 2
}
```

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | Everything green |
| 2 | At least one ⚠ or ✗ finding |
| 99 | Unexpected error |

### CI usage

```yaml
# .github/workflows/dev-vm-drift-check.yml
- run: ./ca-bootstrap.ps1 doctor --json --quiet > drift-report.json
- if: failure()
  run: cat drift-report.json
```

---

## `repair`

Fixes problems doctor would report. Always runs doctor first internally.

### Synopsis

```
./ca-bootstrap.ps1 repair [--all | --target <id>] [flags]
```

You **must** specify either `--all` or `--target` — there is no default to prevent accidental scope creep.

### Targets

| Target | Effect |
|---|---|
| `--all` | Fix every ✗ and ⚠ |
| `--target <tool-id>` | Install/upgrade a specific tool (e.g. `dotnet-10`, `node-20`) |
| `--target repos` | Re-clone or fetch missing/broken repos |
| `--target repos:<slug>` | One specific repo (e.g. `repos:cm-shared-libs`) |
| `--target identity` | Re-write per-folder git identity |
| `--target gh-auth` | Re-run `gh auth login` |
| `--target folders` | Recreate any missing top-level folders |
| `--target journal` | Rebuild the journal from on-disk state |

### Flags

| Flag | Effect |
|---|---|
| `--auto-confirm` | Skip per-fix `[Y/n]` prompts (still prompts for destructive actions). |
| `-Unattended -ConfigFile <path>` | Non-interactive run. |
| `-WhatIf` | Show what would be repaired, change nothing. |

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | All targets brought to ✓ |
| 1 | User quit |
| 9 | One or more targets could not be repaired (run `doctor` for residual issues) |
| 99 | Unexpected error |

---

## `undo`

Reverses changes ca-bootstrap recorded in the action journal.

### Synopsis

```
./ca-bootstrap.ps1 undo [--target <id>] [flags]
```

Default behavior (no `--target`): walk every reversible journal entry, prompting the user per category (Configuration / Cloned repos / Tools / Workspace folder).

### Targets

| Target | Effect |
|---|---|
| (none) | Interactive walkthrough of all reversible categories |
| `--target identity` | Remove per-folder git identity only |
| `--target repos` | Remove cloned repos (per-repo confirm) |
| `--target repos:<slug>` | Remove one specific cloned repo |
| `--target workspace` | Remove the workspace folder if empty |
| `--target journal` | Reset journal entries (no on-disk reversal) |

### Flags

| Flag | Effect |
|---|---|
| `--include-tools` | Also offer to uninstall tools (each requires per-tool confirm). |
| `--include-folders` | Also remove empty top-level folders. |
| `--force` | Override safety rules (uncommitted changes, unknown files). Required for `-Unattended`. |
| `-Unattended -ConfigFile <path>` | Non-interactive run. Requires `--force`. |
| `-WhatIf` | Show what would be undone, change nothing. |

### Safety rules (always enforced)

ca-bootstrap **refuses to delete**:

- A directory containing **uncommitted git changes** (without `--force`).
- A directory containing files **not recorded in the journal** (without `--force`).
- A workspace folder that is **not empty** (without `--include-folders`).
- A tool installation **without `--include-tools`** (and without per-tool confirmation).

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | All requested reversals completed |
| 1 | User quit |
| 7 | Mid-operation failure; partial state — see journal for what was reversed |
| 8 | Refused to proceed (safety rule triggered, missing `--force`) |
| 99 | Unexpected error |

---

## `repos-drift`

Detect drift between `manifest/repos.yaml` and the actual repositories in the ChannelAssist GitHub organization.

### Synopsis

```
./ca-bootstrap.ps1 repos-drift [--json]
make repos-drift
```

### Description

Compares the repos listed in `manifest/repos.yaml` against the live set of non-archived repos in the ChannelAssist GitHub org via `gh repo list`. Reports two categories of drift:

1. **In manifest but not in org** — repos listed in the manifest that don't exist on GitHub (may have been deleted, renamed, archived, or transferred).
2. **In org but not in manifest** — repos that exist on GitHub but aren't tracked in the manifest (new repos that should potentially be added).

### Flags

| Flag | Effect |
|---|---|
| `--json` | Output structured JSON for CI/scripting (includes timestamps and counts). |

### Output formats

#### Default (human)

```
Repository Drift Report

⚠ Drift detected
  Manifest: 17 repos
  GitHub org: 18 repos

In manifest but not in GitHub org (1):
  • ChannelAssist/cm-claim-checker

These repos may have been:
  - Deleted
  - Renamed (check GitHub org for similar names)
  - Archived (use --include-archived to see archived repos)
  - Transferred to another org

Action: Remove these entries from manifest/repos.yaml

In GitHub org but not in manifest (2):
  • ChannelAssist/new-service
  • ChannelAssist/experimental-tool

These are repos that exist but are not tracked in the manifest.
Action: Add entries to manifest/repos.yaml if they should be cloned by setup.

Template for adding to manifest/repos.yaml:

  - { repo: ChannelAssist/new-service, into: <group>/new-service, branch: main }
  - { repo: ChannelAssist/experimental-tool, into: <group>/experimental-tool, branch: main }
```

#### `--json`

```json
{
  "schema_version": 1,
  "timestamp": "2026-05-07T14:30:00Z",
  "drift_detected": true,
  "manifest_repo_count": 17,
  "org_repo_count": 18,
  "in_manifest_not_in_org": [
    "ChannelAssist/cm-claim-checker"
  ],
  "in_org_not_in_manifest": [
    "ChannelAssist/new-service",
    "ChannelAssist/experimental-tool"
  ]
}
```

### Exit codes

| Exit | Meaning |
|---|---|
| 0 | No drift detected — manifest is in sync with org |
| 2 | Drift detected — manual action required |
| 99 | Unexpected error (gh not authenticated, network failure, etc.) |

### Prerequisites

- `gh` CLI must be installed and authenticated (`gh auth status` succeeds).
- User must have read access to the ChannelAssist organization.

### CI usage

```yaml
# .github/workflows/manifest-drift-check.yml
- run: make repos-drift
  continue-on-error: true
- if: failure()
  run: |
    echo "::warning::manifest/repos.yaml is out of sync with the GitHub org"
    ./ca-bootstrap.ps1 repos-drift --json > drift-report.json
    cat drift-report.json
```

### Manual workflow

1. Run `make repos-drift` to detect drift.
2. For repos **in manifest but not in org**:
   - Verify the repo was deleted/renamed/archived on GitHub
   - Remove the entry from `manifest/repos.yaml`
3. For repos **in org but not in manifest**:
   - Decide if the repo should be cloned during setup
   - If yes, add an entry to the appropriate group in `manifest/repos.yaml`
   - Choose the correct `into` path (namespace by product/platform)
   - Set the correct branch (check the repo's default branch)
4. Commit and PR the manifest changes.

### Notes

- Only non-archived repos are considered by default. Archived repos in the org are ignored.
- The comparison is case-insensitive (GitHub repo slugs are case-preserving but case-insensitive).
- This command is read-only and never modifies `manifest/repos.yaml` — it only reports drift.
- Exit code 2 (drift detected) is treated as success by the Makefile target to avoid breaking CI on legitimate drift findings.

---

## Common flags

These flags work on every command:

| Flag | Effect |
|---|---|
| `-Tui` | Require the cab-tui Textual front-end; error out if it isn't installed. (Setup-only; ignored on doctor/repair/undo.) |
| `-NoTui` | Force the legacy Read-Host CLI even when cab-tui is available. (Setup-only.) |
| `-Verbose` | Stream every shell command to the console |
| `-LogPath <path>` | Override transcript location |
| `-ConfigFile <path>` | Provide answers.yaml for unattended mode |
| `--manifest-dir <path>` | Override the manifest directory (defaults to bundled) |
| `--journal <path>` | Override the journal location (defaults to `~/.ca-bootstrap/journal.yaml`) |
| `--no-color` | Disable ANSI color output |
| `-ForceUnlock` | Remove `~/.ca-bootstrap/session.lock` before acquiring; for breaking out of stale locks left by a crashed run |
| `--help` / `-h` | Show command help |
| `--version` | Print ca-bootstrap version and exit |

`setup` also honours two environment variables that act like long-lived flag opt-outs:

| Env var | Effect |
|---|---|
| `CA_BOOTSTRAP_NO_TUI=1` | Same as passing `-NoTui` — useful in CI / login profiles. |
| `CA_BOOTSTRAP_NO_VENV=1` | Skip the `cab-tui/.venv` preference in `Find-CABPython`; useful when you want a Poetry-managed venv to win. See [`tui.md`](tui.md#installing). |

## Concurrency

ca-bootstrap holds an exclusive `session.lock` for the duration of any session that mutates state (`setup`, `repair`, `undo`). `doctor` is read-only and bypasses the lock.

If a previous run crashed without releasing the lock, the next invocation auto-detects the stale lock (the recorded PID either no longer exists or isn't a PowerShell process) and removes it transparently.

If the auto-clean heuristic fails for any reason, the user sees a clean message:

```
  Another ca-bootstrap session is already running.
    Lock file: /Users/.../.ca-bootstrap/session.lock
    Holder   : pid=12345 started=2026-05-04T15:00:00Z

  If the previous run crashed and the lock is stale, run:
      ca-bootstrap.ps1 setup -ForceUnlock
  Otherwise wait for the other session to finish.
```

Exit code: **5** when locked.

---

## See also

- [`action-journal.md`](action-journal.md) — how state is tracked across runs
- [`tui.md`](tui.md) — cab-tui (Textual front-end) user guide and installation
- [`rpc-protocol.md`](rpc-protocol.md) — JSON-RPC wire format between orchestrator and cab-tui
- [`textual-plan.md`](textual-plan.md) — TUI architecture and phase log
- [`../DESIGN.md`](../DESIGN.md) — full design specification
