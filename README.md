# ca-bootstrap

One command to take a fresh laptop to a working ChannelAssist development environment. Runs on Windows, macOS, and Linux.

> **Status: design phase.** This directory currently holds the design specification ([`DESIGN.md`](DESIGN.md)) and example manifests. The runnable scripts are not yet implemented. See [DESIGN.md → Build sequence](DESIGN.md#15-build-sequence) for the planned implementation order.

---

## Quick start (planned)

### Windows

```powershell
iwr -useb https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.ps1 | iex
```

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.sh | bash
```

That's it. The bootstrap script ensures PowerShell 7+ is installed, clones this repository to a cache directory, and launches the interactive onboarding wizard.

---

## What it does

1. **Welcome** — explains what's about to happen and lets you back out
2. **Check prerequisites** — detects which tools are installed at which versions
3. **Install missing tools** — git, GitHub CLI, .NET SDK 10, Node.js 20 LTS, Python 3.12, Docker, VS Code, VS Code extensions
4. **Authenticate** — runs `gh auth login` so private repos can clone
5. **Pick a workspace location** — defaults to `~/Documents/Projects/Work/ChannelAssist/ChannelAssistDev/`
6. **Create the folder structure** — `docs/`, `ca-platform/`, `cm-product/`, `ado-legacy/`
7. **Clone repositories** — group by group, individually selectable, respects your team membership
8. **Configure git identity** — per-folder, so personal repos elsewhere stay untouched
9. **Optional extras** — Claude Code, ca-claude-plugin, WSL2 (Windows), Docker Desktop license acceptance

Every step is **interactive and optional**. Defaults are sensible. You can quit any time. Re-running is safe and acts as a "verify my setup" check.

---

## What gets installed

See [`docs/install-matrix.md`](docs/install-matrix.md) for the full table. Summary:

| Tool | Windows | macOS | Linux |
|---|---|---|---|
| git | winget Git.Git | brew git | apt/dnf git |
| GitHub CLI | winget GitHub.cli | brew gh | apt/dnf gh |
| .NET SDK 10 | winget Microsoft.DotNet.SDK.10 | brew dotnet@10 | dotnet-install.sh |
| Node.js 20 | winget OpenJS.NodeJS.LTS | brew node@20 | nvm |
| Python 3.12 | winget Python.Python.3.12 | brew python@3.12 | apt/dnf python3.12 |
| Docker Desktop | winget Docker.DockerDesktop | brew Docker | apt docker-ce |
| VS Code | winget Microsoft.VisualStudioCode | brew --cask visual-studio-code | apt code |
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
│   ├── user-guide.md
│   ├── install-matrix.md
│   ├── manifest-schema.md
│   ├── auth-flow.md
│   ├── action-journal.md      # how state is tracked for undo
│   ├── troubleshooting.md
│   └── contributing.md
└── tests/                     # Pester tests for lib/, steps/, commands/
```

---

## Contributing

To add a new repo, tool, or step, see [`docs/contributing.md`](docs/contributing.md). Most changes are YAML edits — no code required.

---

## License

Proprietary to ChannelAssist Inc. Public-readable for the bootstrap one-liner; the manifest enumerates private repos but does not expose their contents.

---

## See also

- [`DESIGN.md`](DESIGN.md) — full design specification
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — common failures and fixes
- [Public org profile](https://github.com/ChannelAssist) — repo landscape this bootstraps
