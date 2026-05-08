# ca-bootstrap

One command to take a fresh laptop to a working ChannelAssist development environment. Runs on Windows, macOS, and Linux.

> **Status: v1.0.0** — all four commands are feature-complete. CI runs on Windows, macOS, and Linux (`.github/workflows/ci.yml`).

---

## Quick start

### Windows

```powershell
iwr -useb https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.ps1 | iex
```

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.sh | bash
```

(Pin to a release tag instead of `main` if you want stability — e.g. swap `main` for `v1.0.0`.)

That's it. The bootstrap script ensures PowerShell 7+ and git are installed (prompting first; uses `winget` on Windows, `brew` on macOS, `apt`/`dnf` on Linux), clones this repository to a cache directory, and launches the interactive onboarding wizard.

### From a clone

If you've cloned this repo (e.g. for development), the daily-driver invocation is the make targets:

```bash
make setup                          # the interactive wizard
make doctor                         # diagnose (drift = ok, not a make failure)
make repair ARGS='--all'            # fix everything
make repair ARGS='--target dotnet-10'  # fix one thing
make undo ARGS='--force'            # reverse
make smoke                          # quick end-to-end test
make test                           # Pester
make release VERSION=X.Y.Z          # cut a new release
```

Or directly invoke any of the three equivalent entry points:

```bash
pwsh ./ca-bootstrap.ps1 doctor      # the orchestrator itself
./bootstrap.sh doctor               # forwards to ca-bootstrap.ps1 from a clone
./bootstrap.ps1 doctor              # likewise on Windows
```

> `bootstrap.sh` / `bootstrap.ps1` are the curl-pipe entrypoints. From a clone they auto-detect their sibling `ca-bootstrap.ps1` and forward args, so you never need to remember which is which.

### Recovering from a stale lock

ca-bootstrap holds an exclusive `~/.ca-bootstrap/session.lock` so two parallel `setup` runs can't corrupt the journal. If a previous run crashed, the next run normally auto-detects the stale lock and clears it. If that heuristic fails:

```bash
./ca-bootstrap.ps1 setup -ForceUnlock     # break the lock and retry
```

`doctor` doesn't take the lock (read-only).

### Manual prerequisite install

If you'd rather install PowerShell 7 yourself first:

| OS | Command |
|---|---|
| Windows | `winget install Microsoft.PowerShell` |
| macOS | `brew install --cask powershell` |
| Debian/Ubuntu | See [Microsoft's install guide](https://learn.microsoft.com/powershell/scripting/install/install-debian) |
| RHEL/Fedora | `sudo dnf install powershell` (after adding the Microsoft repo) |

Then:

```bash
git clone https://github.com/ChannelAssist/ca-bootstrap
cd ca-bootstrap
pwsh ./ca-bootstrap.ps1 setup
```

---

## What it does

1. **Welcome** — explains what's about to happen and lets you back out
2. **Check prerequisites** — detects which tools are installed at which versions
3. **Install missing tools** — git, GitHub CLI, PowerShell 7+, GNU Make, .NET SDK 10, Node.js 20 LTS, Python 3.12, Docker, VS Code, VS Code extensions, Claude Code, GitHub Copilot CLI, gh-copilot extension
4. **Authenticate** — runs `gh auth login` so private repos can clone
5. **Pick a workspace location** — defaults to `~/Documents/Projects/ChannelAssistDev/` (Windows: `%USERPROFILE%\Documents\Projects\ChannelAssistDev\`). On a headless box where `~/Documents/` doesn't exist, the default falls back to `~/Projects/ChannelAssistDev/`.
6. **Create the folder structure** — `docs/`, `ca-platform/`, `cm-product/`, `ado-legacy/`
7. **Clone repositories** — group by group, individually selectable, respects your team membership
8. **Configure git identity** — per-folder, so personal repos elsewhere stay untouched
9. **Optional extras** — VS Code multi-root workspace file, workspace-root `.vscode/` defaults (extensions/settings/launch/tasks), ca-claude-plugin (Claude Code plugin), ca-copilot-plugin usage notes (GitHub Copilot custom agents + prompts), WSL2 (Windows-only)

   *(Claude Code itself, the GitHub Copilot CLI, the gh-copilot extension, and the GitHub Copilot VS Code extensions are installed earlier as part of step 3, "Install missing tools" — they live in `manifest/tools.yaml`, not in this Optional extras step.)*

Every step is **interactive and optional**. Defaults are sensible. You can quit any time. Re-running is safe and acts as a "verify my setup" check.

---

## What gets installed

See [`manifest/tools.yaml`](manifest/tools.yaml) for the full machine-readable list. Summary:

| Tool | Windows | macOS | Linux |
|---|---|---|---|
| git | winget Git.Git | brew git | apt/dnf git |
| GitHub CLI | winget GitHub.cli | brew gh | apt/dnf gh |
| PowerShell 7+ | winget Microsoft.PowerShell | brew --cask powershell | apt/dnf powershell (MS repo) |
| GNU Make | winget GnuWin32.Make | brew make | apt/dnf make |
| .NET SDK 10 | winget Microsoft.DotNet.SDK.10 | brew dotnet@10 | dotnet-install.sh |
| Node.js 20 | winget OpenJS.NodeJS.LTS | brew node@20 | nvm |
| Python 3.12 | winget Python.Python.3.12 | brew python@3.12 | apt/dnf python3.12 |
| Docker Desktop | winget Docker.DockerDesktop | brew Docker | apt docker-ce |
| VS Code | winget Microsoft.VisualStudioCode | brew --cask visual-studio-code | apt code |
| Claude Code | npm i -g @anthropic-ai/claude-code | npm i -g @anthropic-ai/claude-code | npm i -g @anthropic-ai/claude-code |
| GitHub Copilot CLI | npm i -g @github/copilot | npm i -g @github/copilot | npm i -g @github/copilot |
| gh-copilot extension | gh extension install github/gh-copilot | gh extension install github/gh-copilot | gh extension install github/gh-copilot |
| WSL2 + Ubuntu | wsl --install (optional) | n/a | n/a |

All installs are **optional and confirmable**. If you already have a tool at the right version, the script detects it and skips.

---

## Commands

ca-bootstrap is a multi-command CLI. The bootstrap one-liner runs the default `setup` command; once installed you can invoke any of the four:

| Command | Purpose |
|---|---|
| `setup` (default) | Full interactive onboarding wizard |
| `doctor` | Diagnose current state. No changes; exits non-zero if anything's wrong |
| `repair` | Fix issues identified by doctor. Targeted (`--target tool-id`) or full (`--all`) |
| `undo` | Reverse changes ca-bootstrap made (per the action journal) |

```powershell
./ca-bootstrap.ps1                          # same as: setup
./ca-bootstrap.ps1 setup                    # full wizard
./ca-bootstrap.ps1 doctor                   # diagnose
./ca-bootstrap.ps1 repair --all             # fix everything doctor found
./ca-bootstrap.ps1 repair --target dotnet-10
./ca-bootstrap.ps1 undo                     # interactive reversal
./ca-bootstrap.ps1 undo --target identity   # reverse just one thing
```

### Common flags (all commands)

| Flag | Effect |
|---|---|
| `-Unattended -ConfigFile <path>` | Non-interactive run; all decisions from YAML. See [`manifest/answers.example.yaml`](manifest/answers.example.yaml). |
| `-WhatIf` | Dry-run; show what would happen, change nothing. |
| `-Verbose` | Stream every shell command to console (in addition to the transcript log). |
| `-LogPath <path>` | Override the default transcript location. |

### Typical usage

| Situation | Command |
|---|---|
| First day on the job | `setup` (via the bootstrap one-liner) |
| "Is my machine still set up correctly?" | `doctor` |
| Doctor reported a missing tool / drifted config | `repair --all` (or targeted) |
| "Add the new repo we created last week" | `setup` again — it's idempotent and only does new work |
| Leaving the company / refreshing the laptop | `undo` |
| CI / IT pre-provisioning a new VM | `setup -Unattended -ConfigFile <answers>.yaml` |

See [`docs/commands.md`](docs/commands.md) for the full reference.

---

## Layout

```
ca-bootstrap/
├── README.md                  # this file
├── DESIGN.md                  # comprehensive design specification
├── bootstrap.sh               # *nix entry point (installs pwsh, clones repo, hands off)
├── bootstrap.ps1              # Windows entry point
├── ca-bootstrap.ps1           # multi-command orchestrator (setup/doctor/repair/undo)
├── lib/                       # shared helpers (UI, platform detection, git ops, journal)
├── commands/                  # one file per top-level command
│   ├── setup.ps1
│   ├── doctor.ps1
│   ├── repair.ps1
│   └── undo.ps1
├── steps/                     # numbered step modules used by setup/doctor/repair
│   ├── 10-welcome.ps1
│   ├── 20-prereqs.ps1
│   ├── 30-gh-auth.ps1
│   ├── 40-workspace.ps1
│   ├── 50-folders.ps1
│   ├── 60-repos.ps1
│   ├── 70-git-identity.ps1
│   └── 80-extras.ps1
├── manifest/                  # YAML data
│   ├── folders.yaml           # folder structure to create
│   ├── repos.yaml             # repos to clone, grouped
│   ├── tools.yaml             # tools to detect and install per OS
│   └── answers.example.yaml   # unattended-mode template
├── docs/                      # extended documentation
│   ├── commands.md            # full reference for setup/doctor/repair/undo
│   └── action-journal.md      # how state is tracked for undo
├── templates/                 # files copied into the developer's workspace
│   └── dot-vscode/            # → `<workspace>/.vscode/` (extensions/settings/launch/tasks)
├── wiki/                      # GitHub Wiki working tree (gitignored; sync with `make wiki-update`)
├── scripts/                   # release.sh, wiki-sync.sh, etc.
└── tests/                     # Pester tests for lib/, steps/, commands/
```

---

## Contributing

Most changes are YAML edits, no code required:

| Change | Edit |
|---|---|
| Add a repo | [`manifest/repos.yaml`](manifest/repos.yaml) |
| Add a tool / change install method | [`manifest/tools.yaml`](manifest/tools.yaml) |
| Add a folder to the workspace skeleton | [`manifest/folders.yaml`](manifest/folders.yaml) |
| Adjust default unattended answers | [`manifest/answers.example.yaml`](manifest/answers.example.yaml) |
| Change the workspace `.vscode/` defaults | [`templates/dot-vscode/`](templates/dot-vscode/) (renamed at copy-time to `.vscode/`) |

For larger changes (a new step, a new command, a reverser), the architecture is documented in [`DESIGN.md`](DESIGN.md). PRs welcome; CI runs Pester + shellcheck on every push (Windows, macOS, Linux).

### Branch model

Following the ChannelAssist org convention:

| Branch | Role |
|---|---|
| `dev` | Default. Feature PRs target this branch. CI runs on every PR. |
| `main` | Release source of truth. Only advances via fast-forward from `dev` at release time. Tagged `vX.Y.Z` on every release. |

The bootstrap one-liners pin to `main`, so end-users always pull the most recently released code (not work-in-progress on `dev`).

### Cutting a release

```bash
# 1. Open a PR to dev that bumps $Script:CABootstrapVersion in ca-bootstrap.ps1
#    (and adds a CHANGELOG entry if you keep one).
# 2. Merge that PR.
# 3. From the repo root:
make release VERSION=1.5.0
```

`make release` runs in this order: dependency check (`gh`/`jq`/`diff`), interactive manifest review (skip with `SKIP_MANIFEST_EDIT=1`), smoke + Pester (skip with `SKIP_SMOKE=1` / `SKIP_TESTS=1`), confirmation gate, ff-promote `origin/dev` → `origin/main` via the disable-restore play on `main-protection`, GPG-signed tag, push, GitHub release. An `EXIT` trap restores main-protection even if a mid-flight step fails.

`make release-dry-run VERSION=1.5.0` validates everything without mutating. See [`docs/commands.md#make-release`](docs/commands.md) for the full reference.

#### One-shot variant: `make release-full`

Skip the manual bump-PR step:

```bash
make release-full VERSION=1.5.0
```

Auto-creates a `chore/v1.5.0-release` branch off `dev`, bumps the version, opens a PR, admin-merges it via the `dev-protection` disable-restore play, then continues into the same `make release` chain. Tradeoff: the bump itself isn't reviewed (single-maintainer / hotfix flow). Use `make release` if your team wants the bump PR to go through normal review.

`make release-full-dry-run VERSION=1.5.0` validates the bump+merge plan without mutating. If the bump is genuinely needed (dev's version differs from the target) the dry-run short-circuits before invoking `scripts/release.sh` — it can't simulate "dev would be bumped, then release.sh runs against the new version" without actually bumping. To dry-run the release.sh half too, manually bump dev first then run `make release-dry-run`.

---

## License

Proprietary to ChannelAssist Inc. Public-readable for the bootstrap one-liner; the manifest enumerates private repos but does not expose their contents.

---

## See also

- [`DESIGN.md`](DESIGN.md) — full design specification (architecture, data shapes, design rationale)
- [`docs/commands.md`](docs/commands.md) — per-command reference: flags, exit codes, output formats
- [`docs/action-journal.md`](docs/action-journal.md) — journal format, recovery, per-action reversal rules
- [Wiki](https://github.com/ChannelAssist/ca-bootstrap/wiki) — same docs, GitHub-rendered
- [Public org profile](https://github.com/ChannelAssist) — the repo landscape this bootstraps
