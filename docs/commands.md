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
| `make nuke` | Full purge: undo every journaled action + remove `~/.ca-bootstrap/`. Confirm-gated (interactive `YES` prompt). `INCLUDE_TOOLS=1` also uninstalls system tools (destructive across the machine). `CONFIRM=1` skips the prompt. `DRY_RUN=1` prints the plan only. See [the dedicated section](#nuke) below. |
| `make tool-list` | Print every tool ID from `manifest/tools.yaml`. Use these IDs with `tool-install` / `tool-update` / `tool-remove`. |
| `make tool-install TOOL=<id>` | `pwsh ./ca-bootstrap.ps1 repair --target <id>`. Idempotent — no-op if the installed version is already at/above the manifest minimum. |
| `make tool-update TOOL=<id>` | Alias for `tool-install` (repair is version-aware: installs if missing, upgrades if below manifest min, no-op otherwise). |
| `make tool-remove TOOL=<id>` | `pwsh ./ca-bootstrap.ps1 undo --target tool.<id> -IncludeTools -Force`. Implicitly destructive — uninstall the named tool. Still prompts once per tool ("Other projects may depend on it") — that confirmation is deliberately not bypassable. |
| `make test` | Full Pester suite. |
| `make smoke` | End-to-end smoke test against a /tmp workspace. |
| `make wiki-clone` / `wiki-sync` / `wiki-push` / `wiki-update` | GitHub Wiki workflow — clone the wiki repo, mirror docs/ into it, push. `wiki-update` does sync + push. |
| `make release VERSION=X.Y.Z` | Promote `dev` → `main` (ff), tag GPG-signed, push, create GH release. Requires the version constant on `dev` to already equal X.Y.Z — bump it via a PR to `dev` first. |
| `make release-dry-run VERSION=X.Y.Z` | Same, no writes. |
| `make release-full VERSION=X.Y.Z` | One-shot: auto-bump dev's version (admin-merged PR, no review), then run `make release`. Skips review on the bump itself; for hotfixes / single-maintainer flows. |
| `make release-full-dry-run VERSION=X.Y.Z` | Validate the bump+merge plan without mutating. Cascades DRY_RUN to `scripts/release.sh` only when dev's version already matches X.Y.Z (otherwise short-circuits — release.sh can't validate against a version that wasn't actually bumped). |
| `make manifest-drift` | Show drift between `manifest/repos.yaml` and the live ChannelAssist org (read-only). |
| `make manifest-edit` | Interactive editor: list every org repo with `[x]`/`[ ]`, add/remove via prompts. |

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
| `--target <tool-id>` | Install/upgrade a specific tool (e.g. `pwsh`, `make`, `dotnet-10`, `node-20`, `claude-code`, `claude-desktop`, `copilot-cli`, `gh-copilot`) |
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

## `manifest-drift`

Maintenance command: detect drift between `manifest/repos.yaml` and the live ChannelAssist GitHub org. Read-only — does not mutate the manifest.

### Synopsis

```
./ca-bootstrap.ps1 manifest-drift [-Json]
make manifest-drift
```

### What it does

1. Reads `manifest/repos.yaml`.
2. Lists the org's repos via `gh repo list ChannelAssist --limit 1000 --json nameWithOwner,isArchived,isPrivate,defaultBranchRef`.
3. Diffs the two and emits a report in three sections:
   - **Missing**: on GitHub, not archived, and not in the manifest. Output includes a PR-ready YAML snippet, with the `into` path / branch / suggested group filled in. Group suggestion is heuristic: `ca-*` → `ca-platform`, `cm-*` / `channel-manager` → `cm-product`, `.github*` / `Keystone` → `docs`, anything else → `unsorted` (maintainer fixes manually).
   - **Stale**: in the manifest but no longer on GitHub (deleted, renamed, made private). These should be removed from the manifest.
   - **Archived**: present in both, but archived on GitHub. Per maintainer policy, archived repos shouldn't be in the manifest at all (they clone read-only and aren't part of an active dev workspace) — surfacing here means "remove from manifest".

> **Archived-but-not-in-manifest repos are deliberately invisible** to this report. The policy is to ignore them entirely; if you ever want to revive one, unarchive on GitHub first, then re-run `manifest-drift` and it'll show up under Missing.

### Flags

| Flag | Default | Notes |
|------|---------|-------|
| `-Json` | off | Emit a structured JSON report on stdout instead of the human-readable text. Useful for CI gates / pre-commit hooks. |
| `-Org <name>` | `ChannelAssist` | Override the org name (rarely needed). |

### Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | No drift — manifest is in sync with the org. |
| 8 | Drift detected. The make target translates this back to 0 so it doesn't break a `make` chain; the raw `ca-bootstrap.ps1` invocation preserves it. |
| Other | gh CLI is not installed / not authenticated, or the manifest is missing. |

### Output (text mode, sample)

```
===============================
  ca-bootstrap manifest-drift
===============================
  Org: ChannelAssist
  Manifest: /Users/.../manifest/repos.yaml
  Querying gh for org repos... 28 found.

  Manifest: 17 repos across 3 groups
  Org:      28 repos

  ⚠ 11 repo(s) on GitHub but NOT in the manifest:

    Suggested group: ca-platform
      • ChannelAssist/ca-bootstrap — default branch: dev

    Paste under group "ca-platform" in manifest/repos.yaml:
      - { repo: ChannelAssist/ca-bootstrap, into: ca-platform/ca-bootstrap, branch: dev }
```

The maintainer reviews the snippet, edits `manifest/repos.yaml` accordingly, and opens a PR. The tool deliberately doesn't mutate the manifest itself — group assignment for "unsorted" repos is a judgment call that benefits from human review.

---

## `manifest-edit`

Interactive maintenance command: list every repo in the ChannelAssist org against `manifest/repos.yaml`, add/remove single-line entries via prompts. Writes back the manifest with the maintainer's confirmation; aborts the file write if "quit without saving" is chosen.

### Synopsis

```
./ca-bootstrap.ps1 manifest-edit
make manifest-edit
```

### Workflow

```
ca-bootstrap manifest-edit
=========================
  Org:      ChannelAssist
  Manifest: ./manifest/repos.yaml
  Querying gh for org repos... 28 found.

  ⚠ Auto-queued 2 archived-on-GitHub manifest entry(ies) for removal:
      • ChannelAssist/cm-ledger-service (archived; per policy, archived repos don't belong in the manifest)
      • ChannelAssist/team-pulse        (archived; per policy, archived repos don't belong in the manifest)

  Repos in 28-style listing:
    [x]  ChannelAssist/.github                       ca-docs/org-profile-public (main)
    [x]  ChannelAssist/.github-private               ca-docs/org-profile-private (main)
    [x]  ChannelAssist/Generative-AI-for-beginners-dotnet  ca-training/Generative-AI-for-beginners-dotnet (main, opt-in)
    [ ]  ChannelAssist/cm-new-thing  (private)       → suggested group: cm-product
    [-]  ChannelAssist/cm-ledger-service             cm-product/cm-ledger-service (main) [auto-queued for removal]
    ...

  Pending: +0 add, -2 remove

  Action?  [a]  Add a missing repo
           [r]  Remove an existing entry
           [s]  Save and exit (default)
           [q]  Quit without saving
  >
```

### Add path

Prompts for `group` (suggested heuristically: `ca-*` → ca-platform, `cm-*` → cm-product, `.github*` / `Keystone` → docs, else `unsorted`), `into` path (defaulting to `<group>/<name>`), `branch` (defaulting to the repo's actual default), and `opt_in` (default `n`).

### Remove path

Lists every manifest entry by index. Multi-line YAML entries (e.g. the `channel-manager` block with `large` / `warn` / `opt_in` fields) are flagged with **"manual edit needed"** — v1 only mutates single-line compact-flow entries to keep the formatting predictable.

### Archived policy

Archived-on-GitHub repos are treated specially:

- **Already in manifest + archived** → auto-queued for removal at startup (maintainer can un-queue via "quit without saving").
- **Not in manifest + archived** → silently invisible to the editor. They're not add-candidates; if you ever want to revive one, unarchive on GitHub first.

### Release integration

`scripts/release.sh` invokes `manifest-edit` as step 0.5 (after dependency validation, before version verification). If the editor writes any changes to `manifest/repos.yaml`, release.sh aborts with a message: "Commit + push to dev via a PR, merge it, then re-run `make release`." This ensures the release commit on `main` reflects the curated manifest.

Skip via `SKIP_MANIFEST_EDIT=1` for hands-off / CI releases (e.g. hotfix tags that don't need a manifest review).

### Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | User saved (with or without changes) or quit without saving |
| 1 | Operational failure (gh missing/unauthenticated, manifest absent) |

---

## `nuke`

Full-purge wrapper around `undo` + state-dir removal. Reverses every journaled action (workspace folders, cloned repos, git includeIf, plugin link), then removes the entire ca-bootstrap state directory (`~/.ca-bootstrap/` by default). System tools are NOT uninstalled by default — those are typically shared with other projects on the machine, so it's an opt-in.

There is no PowerShell `nuke` subcommand: this lives entirely in `scripts/nuke.sh`, invoked via `make nuke`. The actual destructive operations are performed by the existing `undo` and standard `rm -rf` — `nuke` is just the friendlier surface that wires them together with a confirmation gate.

### Synopsis

```bash
make nuke                    # interactive YES prompt; preserves system tools
make nuke INCLUDE_TOOLS=1    # also uninstall .NET 10 / Node / Python / Docker / VS Code / Claude Code / Copilot CLI
make nuke CONFIRM=1          # skip the prompt (for scripting / CI)
make nuke DRY_RUN=1           # print the plan; no mutations
```

### What gets removed

| Always | With `INCLUDE_TOOLS=1` |
|---|---|
| Workspace top-level folders (per the journal) | Manifest tools (.NET 10, Node 20, Python 3.12, Docker, VS Code, Claude Code, Copilot CLI, …) |
| Cloned repos under those folders | |
| `[includeIf]` block in `~/.gitconfig` | |
| `<workspace>/.gitconfig` (per-folder identity) | |
| Claude plugin symlink at `~/.claude/plugins/ca-claude-plugin` | |
| Everything under `~/.ca-bootstrap/` (journal, runs/, last-run.log, cache, lock dir) | |

### Confirmation prompt

The script prefers `/dev/tty` for the prompt so a piped stdin (`echo y \| make nuke`) can't accidentally confirm. Falls back to stdin if `/dev/tty` isn't open for read+write (CI sandboxes, containers without a controlling terminal). The expected reply is `YES` (uppercase, exact match) — anything else aborts with exit 1.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (or `DRY_RUN=1` plan validated) |
| 1 | User declined the confirmation prompt, or `CA_BOOTSTRAP_STATE` failed the safety guard (empty / `/` / `$HOME` / not ending in `.ca-bootstrap` / fewer than 3 path components) |
| 7 | Inner `undo` hit a mid-operation failure — the state dir is left in place so you can retry. (`commands/undo.ps1` only emits 0 / 1 / 7 today; if a new exit code is added there, the script propagates it here.) |

### Safety notes

- **`INCLUDE_TOOLS=1` is destructive across other projects.** Uninstalling .NET 10 or Node 20 affects every project on the machine that depends on them, not just ChannelAssist. Skip the flag unless you genuinely want those gone.
- **`STATE_DIR` is validated before the rm.** The script refuses if `CA_BOOTSTRAP_STATE` is empty, equals `/`, equals `$HOME`, isn't an absolute path, or doesn't end in `.ca-bootstrap`. This is a guardrail against a misconfigured environment turning a confirmed YES into an `rm -rf $HOME` disaster.
- **`undo` exit codes are propagated.** "Nothing to undo" is exit 0 — that's fine and the script continues. A non-zero exit (user quit mid-undo, mid-operation breakage, safety refusal) is real, and the script bails BEFORE the state-dir removal so the next invocation can retry. Pre-fix, we silently swallowed the code, which masked a flag-binding bug for an entire review cycle.

### Tests

Hermetic Pester coverage at `tests/lib/nuke.tests.ps1`. Each case sets `CA_BOOTSTRAP_STATE` to a temp dir so the rm step never targets the real `~/.ca-bootstrap/`. Covers DRY_RUN, INCLUDE_TOOLS warning text, abort-on-not-YES, full removal under CONFIRM=1, and idempotent re-invocation against an already-clean state.

---

## Per-tool wrappers

`tool-install` / `tool-update` / `tool-remove` are thin Makefile shims around `repair --target <id>` and `undo --target tool.<id> -IncludeTools -Force`. They exist so users don't have to remember the ARGS gymnastics for the common single-tool flow.

### Listing tool IDs

```bash
make tool-list
```

Output is partitioned by `required:` / `optional:` (matching the section headers the Makefile prints) — these mirror the corresponding keys in `manifest/tools.yaml`. Whatever appears here is a valid `TOOL=` value for the install / update / remove targets.

### Install or upgrade

```bash
make tool-install TOOL=dotnet-10
make tool-install TOOL=copilot-cli
```

Idempotent: if the installed version meets the manifest minimum, this is a no-op; otherwise it installs (missing) or upgrades (too old) via the platform-appropriate method (winget on Windows, Homebrew on macOS, apt on Debian/Ubuntu, etc.) declared in `manifest/tools.yaml`.

### Update

```bash
make tool-update TOOL=node-20
```

Alias for `tool-install`. Repair already implements the "install or upgrade" semantics; we expose `update` as a separate verb because that's the word users reach for when they want a fresh version.

### Remove

```bash
make tool-remove TOOL=docker
```

Uninstalls a single tool. Implicitly passes `-Force -IncludeTools` to `undo` because the per-tool intent is unambiguous: if you typed `tool-remove TOOL=docker`, you mean it. Note that `undo` still emits a per-tool confirmation prompt ("Other projects may depend on it") that is deliberately NOT bypassed by `-Force` — answer `y` once to proceed with the actual uninstall.

If `TOOL` is omitted, all three targets exit 2 with a friendly error pointing at `make tool-list`.

---

## See also

- [`action-journal.md`](action-journal.md) — how state is tracked across runs
- [`../DESIGN.md`](../DESIGN.md) — full design specification
