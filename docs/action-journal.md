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
  user: peter
  hostname: DESKTOP-PETER
sessions:
  - id: 2026-05-15T09:30:00Z   # ISO 8601 UTC, used as session key
    command: setup              # 'setup' | 'repair' | 'undo'
    ca_bootstrap_version: 1.0.0
    workspace_path: C:\Users\peter\Documents\Projects\ChannelAssistDev
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
  user: peter-g
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
  previous_global_email: peter.personal@gmail.com  # captured before our change
  new_workspace_email: peter.g@channelassist.com
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
