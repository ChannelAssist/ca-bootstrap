# ca-bootstrap

One command to take a fresh laptop to a working ChannelAssist development environment. A single static binary — no runtime to install — for Windows, macOS, and Linux.

[![CI](https://github.com/ChannelAssist/ca-bootstrap/actions/workflows/ci.yml/badge.svg?branch=dev)](https://github.com/ChannelAssist/ca-bootstrap/actions/workflows/ci.yml)

> CI runs the full Go unit + acceptance suites on **Windows, macOS, and Linux** every push (`.github/workflows/ci.yml`), so the Windows-only code paths (LockFileEx session lock, winget detect/dispatch, UTF-8 console, UAC elevation) get real execution, not just cross-compile checks.

> **Status: v2.0.0-alpha.7 (Go).** This is the **Go rewrite**, distributed as pre-built per-platform binaries via [GitHub Releases](https://github.com/ChannelAssist/ca-bootstrap/releases). It replaces the original PowerShell implementation, now archived under [`legacy/`](legacy/) (last PS release: `v1.9.0`). Rationale and roadmap: [`docs/specs/2026-05-25-go-rewrite-pivot.md`](docs/specs/2026-05-25-go-rewrite-pivot.md). New work proceeds **spec → tests → code**, in that strict order.

---

## Install

Download the binary for your platform from the [latest release](https://github.com/ChannelAssist/ca-bootstrap/releases/latest), verify it against `SHA256SUMS.txt`, and put it on your `PATH`.

> **Code signing:** the release workflow Authenticode-signs the Windows binaries when a signing certificate is configured (see [`docs/guides/windows-code-signing.md`](docs/guides/windows-code-signing.md)). Until the production cert is in place, alpha binaries ship **unsigned** — on Windows, SmartScreen may warn "unknown publisher" → **More info → Run anyway**. That's expected, not a failure.

### Windows (PowerShell)

```powershell
# x64 (use ..._windows_arm64.exe on an ARM device)
$asset = 'ca-bootstrap_v2.0.0-alpha.7_windows_amd64.exe'
irm "https://github.com/ChannelAssist/ca-bootstrap/releases/latest/download/$asset" -OutFile ca-bootstrap.exe

# optional: verify the checksum
irm "https://github.com/ChannelAssist/ca-bootstrap/releases/latest/download/SHA256SUMS.txt" -OutFile SHA256SUMS.txt
(Get-FileHash ca-bootstrap.exe -Algorithm SHA256).Hash.ToLower()   # compare against the matching line

.\ca-bootstrap.exe doctor
```

### macOS / Linux

```bash
# pick your platform asset:
#   macOS Apple Silicon : ca-bootstrap_v2.0.0-alpha.7_darwin_arm64
#   macOS Intel         : ca-bootstrap_v2.0.0-alpha.7_darwin_amd64
#   Linux x64           : ca-bootstrap_v2.0.0-alpha.7_linux_amd64
#   Linux ARM64         : ca-bootstrap_v2.0.0-alpha.7_linux_arm64
ASSET=ca-bootstrap_v2.0.0-alpha.7_darwin_arm64
BASE=https://github.com/ChannelAssist/ca-bootstrap/releases/latest/download

curl -fsSL "$BASE/$ASSET" -o ca-bootstrap
curl -fsSL "$BASE/SHA256SUMS.txt" -o SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt --ignore-missing   # macOS; on Linux: sha256sum -c --ignore-missing

chmod +x ca-bootstrap
sudo mv ca-bootstrap /usr/local/bin/ca-bootstrap

ca-bootstrap doctor
```

---

## Quick start

```bash
ca-bootstrap setup     # the interactive onboarding wizard
ca-bootstrap doctor    # read-only diagnosis (exit 2 = a required tool is missing/old)
```

`setup` is interactive, idempotent, and safe to re-run — a second run acts as a "verify my setup" check and only does new work.

---

## What it does

`setup` runs seven steps, each optional, with sensible defaults; quit any time:

1. **Welcome** — explains what's about to happen and lets you back out.
2. **Prerequisites** — detects installed tooling against the embedded manifest and reports version drift (read-only; `repair` fixes it).
3. **GitHub authentication** — checks `gh auth status`; offers `gh auth login --git-protocol https --web` if you're not signed in (needed to clone private repos).
4. **Git identity** — writes a workspace-scoped `.git/config` `[user]` block, so personal repos elsewhere stay untouched. Default workspace root: `~/Documents/Projects/ChannelAssistDev` (falls back to `~/Projects/ChannelAssistDev` on a headless box).
5. **Folder structure** — creates the workspace taxonomy (`ca-tools/`, `ca-docs/`, `ca-platform/`, `cm-product/`, `ca-training/`, `ca-work-dirs/`), migrates renamed predecessors, and seeds a per-folder `README.md`.
6. **Repository cloning** — clones each group's repos into the workspace, group by group, individually selectable; already-cloned repos are skipped + fetched.
7. **Optional extras** — VS Code multi-root `.code-workspace` file, workspace `.vscode/` defaults, a `ca-claude-plugin` activation link (junction on Windows), `ca-copilot-plugin` usage notes, and a Windows-only WSL2 offer.

Every mutating step is recorded in an append-only action journal (`~/.ca-bootstrap/journal.ndjson`) so `undo` can reverse the session.

---

## Commands

```
ca-bootstrap version    Print version, commit, build time
ca-bootstrap doctor     Diagnose installed tooling against the manifest (read-only)
ca-bootstrap setup      Interactive wizard (welcome → prereqs → gh-auth → identity → folders → repos → extras)
ca-bootstrap repair     Install missing tools — all required by default; --all adds optional; --target <id> for one
ca-bootstrap undo       Reverse changes recorded in the action journal
```

`setup`'s prerequisites step **offers to install** any missing required tools inline (the same install path as `repair`); `repair` with no arguments fixes everything that's missing. You don't need to know tool ids.

| Command | Key flags |
|---|---|
| `setup` | `--unattended --config <file>` (non-interactive; reads a YAML answer file) |
| `repair` | *(no flags)* installs all missing **required** tools; `--all` also installs optional; `--target <id>` installs one; `--unattended --config <file>`, `--ForceUnlock` |
| `undo` | `--target identity\|tools\|tool:<id>`, `--include-folders` (remove non-empty folders), `--include-tools` (uninstall), `--force` (skip confirm; required for `--unattended`), `--ForceUnlock` |
| `doctor` | `--deep` runs capability self-test probes (workspace write, symlink/junction, package manager reachable, gh auth); `--deep --full` adds a real install→uninstall round-trip on an absent probe tool |

`doctor` exit codes: **0** = all good, **2** = a required tool is missing or below its minimum version, or (under `--deep`) a capability probe failed; **1** = a manifest/IO failure. Bare `doctor` is fast and read-only; `--deep` is opt-in because its probes write (and clean up) temp files.

### Unattended mode

`setup`, `repair`, and `undo` accept `--unattended --config <file>`, reading every decision from a YAML answer file (keys map to the interactive prompts). Used for CI / IT pre-provisioning. `undo --unattended` additionally requires `--force`.

---

## Tools

The required/optional tool set lives in the embedded manifest ([`internal/manifest/tools.yaml`](internal/manifest/tools.yaml)).

**Required** (`doctor` flags any missing one as drift): `git`, `gh` (GitHub CLI), `pwsh` (PowerShell 7+), `make` (GNU Make), `az` (Azure CLI), `jq`, `psql` (PostgreSQL client), `copilot-cli` (GitHub Copilot CLI).

**Optional** (detected, installable on demand): `dotnet-10`, `kubectl`, `helm`, `node-20`, `python-312`, `docker`, `vscode`, `claude-code`.

`ca-bootstrap repair` installs all missing required tools (add `--all` for optional too, or `--target <id>` for just one) — it reads the per-OS install block (winget on Windows, brew on macOS, apt/dnf/snap/script on Linux, npm for the Node-based CLIs) and runs it after a single confirmation.

---

## Build from source

Requires Go 1.23+.

```bash
git clone https://github.com/ChannelAssist/ca-bootstrap
cd ca-bootstrap
go build -o ca-bootstrap ./cmd/ca-bootstrap
./ca-bootstrap version

# tests
go test ./...                          # unit
go test -tags acceptance ./tests/acceptance   # acceptance
```

Manifests are embedded at build time. For local experiments you can override them: `CA_BOOTSTRAP_MANIFEST`, `CA_BOOTSTRAP_REPOS`, `CA_BOOTSTRAP_FOLDERS` point at alternate YAML files.

---

## Layout

```
ca-bootstrap/
├── cmd/ca-bootstrap/         # main package; console UTF-8 shim; ldflags version vars
├── internal/
│   ├── cli/                  # cobra commands: version, doctor, setup, repair, undo
│   ├── detect/               # tool detection + version parsing (per-OS probes)
│   ├── manifest/             # embedded tools.yaml / repos.yaml / folders.yaml + loaders
│   ├── ghauth/               # gh auth status/login/logout wrappers
│   ├── identity/             # workspace git identity read/write/restore
│   ├── folders/              # folder taxonomy + embedded README templates
│   ├── repos/                # gh repo clone orchestration
│   ├── extras/               # VS Code workspace, .vscode defaults, plugin link, WSL
│   ├── install/              # per-package-manager install / uninstall dispatch
│   ├── journal/              # append-only NDJSON action journal
│   ├── lock/                 # exclusive session lock
│   ├── undo/                 # undo orchestrator + reversers/
│   └── wizard/               # wizard engine + steps/
├── tests/acceptance/         # build-tagged end-to-end tests + YAML fixtures
├── tests/smoke/              # live Windows end-to-end smoke harness (PowerShell)
├── docs/guides/              # operator guides (e.g. Windows code signing)
├── docs/specs/               # spec-first design docs (one per alpha)
├── dist/                     # local release artifacts (gitignored)
└── legacy/                   # archived PowerShell implementation (v1.9.0)
```

---

## Contributing

New work is **spec → tests → code**, in that strict order; each alpha has a spec in [`docs/specs/`](docs/specs/). Conventional Commits, GPG-signed, bisected (one logical change per commit).

### Branch & release model

| Branch | Role |
|---|---|
| `dev` | Default. Feature PRs target this branch (squash-merged). |
| `main` | Release source of truth. `dev` is promoted to `main` via a **merge commit** at release time, then tagged `vX.Y.Z` and a GitHub Release is cut with per-platform binaries + `SHA256SUMS.txt`. |

Branch from `dev`, PR back into `dev`. See [`CHANGELOG.md`](CHANGELOG.md) for the release history and [`CLAUDE.md`](CLAUDE.md) for the SDLC conventions this repo follows.

---

## License

Proprietary to ChannelAssist Inc.
