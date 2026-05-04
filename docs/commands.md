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
| `make setup` | `pwsh ./ca-bootstrap.ps1 setup` |
| `make doctor` | `pwsh ./ca-bootstrap.ps1 doctor` (exits 0 even when drift is found, since drift is a valid output) |
| `make repair ARGS='--all'` | `pwsh ./ca-bootstrap.ps1 repair -All` |
| `make repair ARGS='--target dotnet-10'` | `pwsh ./ca-bootstrap.ps1 repair -Target dotnet-10` |
| `make undo ARGS='--force'` | `pwsh ./ca-bootstrap.ps1 undo -Force` |
| `make smoke` | end-to-end smoke test against a /tmp workspace |
| `make test` | full Pester suite |
| `make release VERSION=X.Y.Z` | full release: bump version, smoke + tests, commit, tag, push, GH release |
| `make release-dry-run VERSION=X.Y.Z` | same, no writes |

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
| 1 | User quit |
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

## Common flags

These flags work on every command:

| Flag | Effect |
|---|---|
| `-Verbose` | Stream every shell command to the console |
| `-LogPath <path>` | Override transcript location |
| `-ConfigFile <path>` | Provide answers.yaml for unattended mode |
| `--manifest-dir <path>` | Override the manifest directory (defaults to bundled) |
| `--journal <path>` | Override the journal location (defaults to `~/.ca-bootstrap/journal.yaml`) |
| `--no-color` | Disable ANSI color output |
| `-ForceUnlock` | Remove `~/.ca-bootstrap/session.lock` before acquiring; for breaking out of stale locks left by a crashed run |
| `--help` / `-h` | Show command help |
| `--version` | Print ca-bootstrap version and exit |

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
- [`troubleshooting.md`](troubleshooting.md) — common failures and their fixes
- [`../DESIGN.md`](../DESIGN.md) — full design specification
