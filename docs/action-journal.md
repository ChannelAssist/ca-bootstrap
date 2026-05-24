# Action journal

The action journal is the source of truth for what ca-bootstrap has done on your machine. It is the foundation that makes `doctor`, `repair`, and `undo` possible.

## Where it lives

```
~/.ca-bootstrap/
├── journal.yaml              # active journal — every recorded action
├── last-run.log              # transcript of the most recent run
├── runs/
│   ├── 2026-05-15T09:30:00Z.log
│   ├── 2026-05-15T11:42:00Z.log
│   └── …                     # last 10 archived
└── journal.yaml.undone-2026-05-15  # snapshots after `undo` runs
```

On Windows the path is `%USERPROFILE%\.ca-bootstrap\`.

## Why it exists

Without a record of what was done:

- **`doctor`** can't tell whether a missing repo means "you opted out" or "something deleted it accidentally."
- **`repair`** can't know which fixes ca-bootstrap is responsible for vs. which were pre-existing.
- **`undo`** can't know which folders to remove without risking a developer's pre-existing data.

The journal answers all three: it is a list of "ca-bootstrap did this" claims, each with enough metadata to verify (for doctor) or reverse (for undo).

## Format

YAML 1.2. Top-level structure:

```yaml
schema_version: 1
host:
  os: windows                  # 'windows' | 'macos' | 'linux-debian' | 'linux-rhel' | 'linux-arch'
  user: user
  hostname: DESKTOP-USER
sessions:
  - id: 2026-05-15T09:30:00Z   # ISO 8601 UTC, used as session key
    command: setup              # 'setup' | 'repair' | 'undo'
    ca_bootstrap_version: 1.0.0
    workspace_path: C:\Users\user\Documents\Projects\ChannelAssistDev
    actions:                    # ordered, oldest first
      - { … }
      - { … }
```

Each `action` has a uniform shape:

```yaml
- id: 2026-05-15T09:30:14Z      # unique within journal
  step: 50-folders               # which step produced it
  action: create_folder          # action type (see table below)
  reversible: true
  undone: false                  # set true after a successful undo
  …                              # action-specific fields
```

## Action types

Listed in the order steps typically produce them.

### `create_folder`

```yaml
- id: ...
  step: 50-folders
  action: create_folder
  path: C:\…\ChannelAssistDev\docs
  reversible: true
  undone: false
```

**Undone by**: `Remove-Item -Path <path>` if the directory is empty (no files, no other entries).

For workspace-root folders the entry also carries `is_workspace_root: true`. That field is what `undo --target workspace` keys off of, and it stays in `create_folder` only when step 40 actually mkdirs — for the per-run "which workspace did setup pick" record (emitted whether the folder was created or already existed), see [`select_workspace`](#select_workspace) below.

### `seed_readme`

```yaml
- id: ...
  step: 50-folders
  action: seed_readme
  path: C:\…\ChannelAssistDev\ca-tools\README.md
  template: C:\…\ca-bootstrap\templates\folder-readmes\ca-tools\README.md
  reversible: true
  undone: false
```

**Used by**: step 50 (and `repair --target folder-readmes`) when copying a folder's canonical `README.md` from `templates/folder-readmes/<folder>/README.md` into the workspace. Idempotent — never overwrites a pre-existing file.

**Undone by**: `Remove-Item -Path <path>` only if the current file still hashes equal to the template recorded at journal time. If the user has edited the README since seeding, the file is preserved (`status: skip`) so a deliberate edit isn't silently destroyed.

### `refresh_readme`

```yaml
- id: ...
  step: repair
  action: refresh_readme
  path: C:\…\ChannelAssistDev\ca-tools\README.md
  template: C:\…\ca-bootstrap\templates\folder-readmes\ca-tools\README.md
  previous_content: SGVsbG8gd29ybGQh                    # base64 of pre-overwrite bytes (≤64KB)
  reversible: true
  undone: false
```

**Used by**: `repair --target folder-readmes` when overwriting a drifted README with the canonical template (after explicit user confirmation per the safety contract). Captures the pre-overwrite content into `previous_content` as base64 so undo can restore it byte-for-byte.

**Capture rules** (set in `Invoke-CABRepairFolderReadmes`):

- File ≤ 64KB of source bytes → `previous_content` written, no `previous_content_captured` marker.
- File > 64KB → no `previous_content` field, plus `previous_content_captured: false` so undo can distinguish "intentionally skipped (too large)" from "never captured (pre-v1.9.0 entry)".
- Pre-overwrite content matches a credential-shaped token under UTF-8 / UTF-16LE / UTF-16BE decode (GH/AWS/Slack/JWT/PEM prefixes per `Test-CABContainsSensitive`) → no `previous_content`, `previous_content_captured: false`, yellow warning. Secrets in a drifted README can't round-trip into the journal via base64.

**Undone by**:

- If `previous_content` key is absent → `status: noop` (legacy entry from before the capture path landed, or a skipped-capture entry; the entry is closed without action).
- If `previous_content` is present:
  - Target README missing → restore the captured bytes (no divergence possible).
  - Target README present AND template still on disk AND `SHA256(README) == SHA256(template)` → restore proceeds.
  - Target present, hash mismatch → `status: skip` ("README has been edited since repair overwrote it"); user edits preserved.
  - Target present, template missing on disk → `status: skip` ("Template no longer at recorded path; cannot verify content match"); user edits preserved.
  - Hash compute throws (transient I/O / permissions) → `status: fail`; restore refused rather than silently proceeding on `$null` hashes.

The divergence guard mirrors the `seed_readme` reverser's discipline exactly so the two README-touching actions behave consistently when the operator may have edited the file after ca-bootstrap last wrote to it.

### `rename_folder`

```yaml
- id: ...
  step: 50-folders
  action: rename_folder
  from: C:\…\ChannelAssistDev\experiments
  to:   C:\…\ChannelAssistDev\ca-experiments
  mode: silent-empty                                    # or: merge-into-empty-new
  reversible: true
  undone: false
```

**Used by**: step 50 (`Invoke-CABStep50`) when a required folder is missing but a predecessor declared in its `renamed_from:` chain still exists on disk, AND by `repair --target folder-renames` when migrating legacy folders to renamed paths.

The `mode` field records which branch of the safety-contract decision table the rename took: `silent-empty` (legacy was empty, renamed in place), `silent-with-content` (legacy had content, user explicitly confirmed), or `merge-into-empty-new` (both paths existed, legacy had content, new was empty, children moved + empty legacy removed).

`renamed_from:` itself can be a scalar (single predecessor) or a list (multi-step rename history walked most-recent → oldest). See [`docs/specs/2026-05-22-folder-taxonomy-design.md`](specs/2026-05-22-folder-taxonomy-design.md).

**Undone by**: `Move-Item -Path <to> -Destination <from>` after verifying both directories exist and `to` is empty (or `--force`).

### `remove_empty_folder`

```yaml
- id: ...
  step: repair
  action: remove_empty_folder
  path: C:\…\ChannelAssistDev\experiments                # always a legacy renamed_from path
  reason: new-populated                                  # or: both-existed-both-empty
  reversible: true
  undone: false
```

**Used by**: `repair --target folder-renames` when the safety contract's both-exist-cleanup branches fire — the legacy folder is empty and the new folder is populated (or both are empty), so the legacy is removed.

**Undone by**: `New-Item -ItemType Directory -Path <path>` (re-creating the empty legacy folder so a subsequent rerun would re-detect drift).

### `refresh_folder_tree`

```yaml
- id: ...
  step: repair
  action: refresh_folder_tree
  folder: ca-platform
  path: C:\…\ChannelAssistDev\ca-platform\README.md
  reversible: false
  undone: false
```

**Used by**: `repair --target folder-tree-refresh` whenever it actually rewrites the `## Tree` fenced block in a folder's `README.md` (no-op runs don't journal anything). The rewrite preserves the file's native line endings (LF vs CRLF) and any pre-existing UTF-8 BOM; the fence search is bounded to the Tree section so an unfenced Tree + later fenced section (`## Examples`) can't cross-contaminate.

**Undone by**: nothing. `reversible: false` because the previous tree content is not captured — the manifest is the source of truth, and any "undo" would re-run the same regenerate. If you want to revert, fix `manifest/repos.yaml` and re-run the target.

### `select_workspace`

```yaml
- id: ...
  step: 40-workspace
  action: select_workspace
  path: C:\…\ChannelAssistDev
  is_workspace_root: true
  created: false                  # true on the run that mkdir'd the folder
  reversible: false
  undone: false
```

Emitted by step 40 on **every** setup run — both when the workspace folder is created and when an existing one is selected. `doctor` reads the most-recent `select_workspace` entry to discover which workspace the user last chose; without it, doctor used to fall back to the most-recent workspace-root `create_folder` and surface a stale earlier choice when the user re-ran setup against an existing path.

**Undone by**: nothing. The action is `reversible: false` and has no per-action reverser — selecting an existing folder has no side effect to undo, and the actual `mkdir` (when it happened) is reversed via the sibling `create_folder` entry. `undo --target workspace` selects entries by the `is_workspace_root` data field regardless of action, so removal is still driven by `create_folder`.

### `install_tool`

```yaml
- id: ...
  step: 20-prereqs
  action: install_tool
  tool: dotnet-10
  method: winget
  package_id: Microsoft.DotNet.SDK.10
  version_installed: 10.0.100
  reversible: true               # but requires --include-tools to actually undo
  reversal_warning: "Other projects on this machine may depend on .NET 10."
  undone: false
```

**Undone by**: `winget uninstall <package_id>` (or platform equivalent), only if the user passes `--include-tools` AND confirms per-tool.

### `gh_auth_login`

```yaml
- id: ...
  step: 30-gh-auth
  action: gh_auth_login
  protocol: https
  user: user-g
  reversible: true
  undone: false
```

**Undone by**: `gh auth logout`.

### `clone_repo`

```yaml
- id: ...
  step: 60-repos
  action: clone_repo
  repo: ChannelAssist/Keystone
  path: C:\…\docs\keystone
  branch: master
  clone_size_bytes: 15728640
  reversible: true
  undone: false
```

**Undone by**: `Remove-Item -Recurse <path>` after verifying:

- The directory still contains the cloned `.git` directory with origin matching `repo`.
- No uncommitted changes (unless `--force`).
- No untracked files unknown to ca-bootstrap (unless `--force`).

### `configure_git_identity`

```yaml
- id: ...
  step: 70-git-identity
  action: configure_git_identity
  workspace: C:\…\ChannelAssistDev
  global_gitconfig_includeif_added: true
  workspace_gitconfig_path: C:\…\ChannelAssistDev\.gitconfig
  previous_global_email: user.personal@example.com  # captured before our change
  new_workspace_email: user@channelassist.com
  reversible: true
  undone: false
```

**Undone by**:

1. Remove the `[includeIf "gitdir:<workspace>/"]` block from `~/.gitconfig`.
2. Delete `<workspace>/.gitconfig`.

### `install_vscode_extension`

```yaml
- id: ...
  step: 80-extras
  action: install_vscode_extension
  extension_id: GitHub.copilot
  reversible: true
  undone: false
```

**Undone by**: `code --uninstall-extension <extension_id>`.

### `install_claude_code`

```yaml
- id: ...
  step: 80-extras
  action: install_claude_code
  npm_global: true
  version_installed: 1.0.0
  reversible: true
  reversal_warning: "Used by other projects."
  undone: false
```

**Undone by**: `npm uninstall -g @anthropic-ai/claude-code` (only with `--include-tools`).

### `install_ca_claude_plugin`

```yaml
- id: ...
  step: 80-extras
  action: install_ca_claude_plugin
  plugin_path: ~/.claude/plugins/ca-claude-plugin
  reversible: true
  undone: false
```

**Undone by**: plugin deactivation + remove plugin directory.

### `show_ca_copilot_plugin_usage`

```yaml
- id: ...
  step: 80-extras
  action: show_ca_copilot_plugin_usage
  repo_path: <workspace>/ca-platform/ca-copilot-plugin
  reversible: false
  undone: false
```

**Undone by**: not undoable. The action is informational only — the agents and prompts in `ca-copilot-plugin/.github/agents/` and `ca-copilot-plugin/.github/prompts/` resolve when synced into a consumer repo's `.github/agents/` and `.github/prompts/` (handled out-of-band by `cm-platform-infra` `make agents-sync`). There is no per-developer install state to reverse.

### `install_wsl`

```yaml
- id: ...
  step: 80-extras
  action: install_wsl
  distro: Ubuntu-22.04
  reversible: false              # wsl --unregister has too many edge cases
  undone: false
```

**Not undone**: ca-bootstrap refuses to reverse this. Prints instructions for manual removal: `wsl --unregister Ubuntu-22.04`.

### `create_workspace_file`

```yaml
- id: ...
  step: 80-extras
  action: create_workspace_file
  path: C:\…\ChannelAssistDev\ChannelAssist.code-workspace
  reversible: true
  undone: false
```

**Undone by**: delete the file.

### `create_file`

```yaml
- id: ...
  step: 80-extras
  action: create_file
  path: C:\…\ChannelAssistDev\.vscode\extensions.json
  reversible: true
  undone: false
```

**Used by**: step 80's workspace-root `.vscode/` defaults (one entry per file written). Step 80 only writes a file when it does not already exist, so each `create_file` entry represents a path ca-bootstrap is responsible for.

**Undone by**: delete the file.

## Lifecycle

### Append-only during a session

While a `setup` or `repair` command is running, new actions are **appended** to the latest session's `actions:` array. Existing entries are never modified.

### Session boundaries

Each invocation of `setup` or `repair` starts a new session entry. The session captures:

- Timestamp and command.
- ca-bootstrap version.
- Workspace path (in case the user picks a different one).
- All actions taken in that session.

If a session is interrupted (Ctrl+C, crash), the partial session entry remains and is replayed by the next `doctor` run for accurate state reporting.

#### Session-required contract (v1.9.0+)

`Add-CABJournalEntry` throws `[CABNoActiveSessionException]` when no session has been started in the current process run. This is a hard contract:

- Every production code path that mutates the workspace MUST be reached from `setup` or `repair` (which both call `Start-CABSession`).
- The read-only commands `doctor` and `manifest-drift` may legitimately skip the session — they don't mutate, so they have no audit trail to write.
- `--json` / `--quiet` modes for the read-only commands skip the session AND the banner; for mutating commands they keep the session (audit trail is preserved) and only suppress the banner via `Start-CABSession -Quiet:$silent` / `Stop-CABSession -Quiet:$silent`.

The throw replaces an earlier silent `$null` return that caused invisible audit-trail gaps in production. A static-audit Pester suite (`tests/lib/journal-session-required.tests.ps1`) enforces the contract by walking every production `.ps1` for `Add-CABJournalEntry` callers and refusing to let new ones land without a paired `Start-CABSession` upstream.

The active session is cached at `$Script:CABActiveSession` for O(1) `Get-CABCurrentSession` lookup. `Read-CABJournal` re-links the cache after any state-replacement (via the `Sync-CABActiveSession` helper) so mid-run reloads from disk — `commands/doctor.ps1` and `commands/undo.ps1` both do this for journal cross-checks — never orphan the cached reference.

### Marking entries as undone

`undo` does not remove journal entries — it sets `undone: true` and adds an `undone_at:` timestamp. This preserves history.

After `undo` completes, ca-bootstrap also writes a snapshot to `journal.yaml.undone-<timestamp>` so the user can inspect what was reversed.

## Recovery

If the journal is lost or corrupted:

```powershell
./ca-bootstrap.ps1 repair --target journal
```

This walks the workspace, the global `~/.gitconfig`, and the installed-tool list to reconstruct best-effort entries. Reconstructed entries are tagged:

```yaml
- id: 2026-05-20T14:00:00Z       # reconstruction time
  reconstructed: true
  reconstructed_warning: "Pre-undo state (e.g. previous_global_email) cannot be recovered."
  step: 70-git-identity
  action: configure_git_identity
  …
```

Reconstructed entries are reversible by `undo` but with weaker guarantees (e.g. the previous global email is unknown, so a reversal can't restore it).

## Multi-machine

Each machine has its own journal. They are **not** synced. This is intentional:

- Different machines may have different installed tools, different workspace paths, different team membership.
- Syncing would create attack surface (a compromised journal could trick `undo` into deleting things on another machine).
- The journal contains absolute paths, which don't survive cross-platform copy.

A future version may add opt-in encrypted sync (see [DESIGN.md → Future work](../DESIGN.md#19-future-work)).

## Privacy and tokens

The journal **never contains**:

- GitHub tokens (gh CLI's credential store is opaque).
- Passwords (we don't collect any).
- File contents from cloned repos.

It **does contain**:

- Absolute filesystem paths.
- Repo slugs and branches.
- Tool versions.
- Your previous global git email (so undo can restore it).

These are all non-secret. The journal lives in your home directory; same trust boundary as `.bashrc` or `.gitconfig`.

## Inspecting

The journal is plain YAML — open it in any editor:

```bash
cat ~/.ca-bootstrap/journal.yaml
less ~/.ca-bootstrap/journal.yaml
code ~/.ca-bootstrap/journal.yaml
```

Common checks:

- "What did the last setup do?" → look at the most recent session's `actions:`.
- "Is this folder mine or ca-bootstrap's?" → grep for the path in the journal.
- "Did I ever install Docker via this tool?" → grep for `tool: docker`.

## See also

- [`commands.md`](commands.md) — how `doctor`/`repair`/`undo` use the journal
- [`../DESIGN.md#8-action-journal`](../DESIGN.md#8-action-journal) — design rationale
- [`troubleshooting.md`](troubleshooting.md) — recovery procedures
