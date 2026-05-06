# cab-tui — Textual front-end for `ca-bootstrap setup`

`cab-tui` is the optional rich-terminal UI for the interactive `setup` flow. The PowerShell wizard is still the source of truth; cab-tui is the rendering layer over a JSON-RPC stdio bridge. Read-Host CLI mode remains fully supported and is the silent fallback when cab-tui isn't installed.

## What you see

```
┌─ Steps ──────────────┬─ Active step / Transcript ─────────────────────┐
│ ✓ Welcome            │ # ChannelAssist developer onboarding           │
│ ✓ Workspace location │                                                │
│ ▶ Prerequisites      │ - install missing tools…                       │
│ ○ GitHub auth        │ - authenticate to GitHub…                      │
│ ○ Folder structure   │                                                │
│ ○ Clone repos        │ ▷▷▷ Installing Docker Desktop… (spinner)       │
│ ○ Git identity       │                                                │
│ ○ Optional extras    │ ChannelAssist/Keystone  ▰▰▰▰▱▱▱▱▱  3 / 14      │
│                      │                                                │
│                      │ [ Yes ] [ No ] [ Quit ]                        │
└──────────────────────┴────────────────────────────────────────────────┘
  q Quit  l Toggle log  ? Help
```

- **Tree pane** — eight setup steps in execution order; status icon (`○ ▶ ✓ ↷ ⚠ ✗`) updates live as the wizard progresses.
- **Active step** — Markdown view of the current step's content.
- **Progress area** — single determinate `ProgressBar` for repo cloning that advances across the whole manifest (current/total, with the active repo's name as the label), and one indeterminate `LoadingIndicator` per tool install.
- **Prompt area** — Whatever question the wizard is asking right now: `Button` row for confirms, `RadioSet` for single-pick, `Checkbox`es for multi-pick, `Input` for free text, prominent red panel for step-failure recovery.
- **Transcript tab** — Full live log; press `l` to flip to it any time.
- **Footer** — Keybindings.

## Keybindings

| Key | Action |
|----|----|
| `q` | Quit (offers rollback of this session's recorded actions) |
| `Ctrl+C` | Same as `q`; press twice to force-exit |
| `l` | Toggle the Active step / Transcript tabs |
| `?` | Show help toast |
| `Tab` / `Shift+Tab` | Cycle between focusable widgets in the prompt area |
| `Enter` | Activate focused button / submit text input / select radio |
| `Space` | Toggle focused checkbox |

Inside a `Button` row, focus follows the prompt's `default` value so pressing `Enter` accepts the recommended answer.

## Enabling the TUI

`-Tui` is opt-in by exception. The orchestrator probes `cab_tui` at start-up and uses it automatically when present:

```powershell
ca-bootstrap.ps1 setup           # auto-detects; uses TUI if installed
ca-bootstrap.ps1 setup -Tui      # require TUI; error if cab-tui isn't installed
ca-bootstrap.ps1 setup -NoTui    # force the legacy Read-Host CLI even when cab-tui is available
```

When auto-detect can't find a usable cab-tui (no `cab-tui/.venv/`, no PATH-resolvable Python with `cab_tui` importable), the orchestrator prints a one-line hint pointing at `make tui-install` and proceeds with the legacy CLI. Set `CA_BOOTSTRAP_NO_TUI=1` (or pass `-NoTui`) to opt out and silence the hint.

From a clone:

```bash
make setup                       # auto-detect
make setup-no-tui                # force CLI
make tui-install                 # pip install -e cab-tui/
```

## Installing

cab-tui needs Python 3.10 or newer.

```bash
make tui-install
```

Or by hand — install into `cab-tui/.venv` (the orchestrator's `Find-CABPython` looks there first, and `pip install` against the system Python is blocked by PEP 668 on Homebrew/system Pythons anyway):

```bash
python3 -m venv cab-tui/.venv
cab-tui/.venv/bin/python -m pip install -e 'cab-tui[dev]'   # quote so zsh doesn't treat [dev] as a glob
```

`poetry.lock` is committed for reproducibility (per SDLC), but `pip install` doesn't read it — pip resolves transitively from the version specifiers in `pyproject.toml`. For a strict lockfile-based install, use Poetry directly. Note: the orchestrator's `Find-CABPython` checks `cab-tui/.venv` **before** PATH, so a Poetry venv on PATH is silently ignored when `cab-tui/.venv/` exists. Set `CA_BOOTSTRAP_NO_VENV=1` to skip the venv-first lookup and let Poetry's interpreter win:

```bash
(cd cab-tui && poetry install)                       # populates Poetry's virtualenv
export PATH="$(cd cab-tui && poetry env info --path)/bin:$PATH"   # add it to PATH
export CA_BOOTSTRAP_NO_VENV=1                        # skip cab-tui/.venv preference
./ca-bootstrap.ps1 setup                             # run from repo root
```

Alternatively, point Poetry at `cab-tui/.venv` directly so the standard venv-first lookup works:

```bash
(cd cab-tui && POETRY_VIRTUALENVS_IN_PROJECT=true poetry install)   # creates cab-tui/.venv
./ca-bootstrap.ps1 setup                                            # default lookup finds it
```

Or export the lockfile to a pip-compatible constraints file (`poetry export --without-hashes -o constraints.txt`) and pip-install into `cab-tui/.venv` with `--constraint`.

The bootstrap one-liners (`bootstrap.sh` / `bootstrap.ps1`) install Python and cab-tui automatically when missing — no manual step required for first-time users.

### macOS Python 3.14 + hatchling note

Hatchling's editable backend writes its `.pth` shim with the macOS `UF_HIDDEN` flag set. Python 3.14's site.py skips hidden `.pth` files, which would silently break `import cab_tui` from any working directory other than `cab-tui/`. `make tui-install` clears the flag automatically. `lib/tui-rpc.ps1` also sets `PYTHONPATH=<repo>/cab-tui` on the spawned bridge as defense-in-depth, so a stale install won't break the orchestrator either.

## Accessibility

- **High-contrast and screen-reader friendly** by virtue of using stock Textual widgets. Textual emits ANSI sequences that respect `NO_COLOR` and the `prefer-reduced-motion` CSS hint.
- **No mouse required.** Every prompt and panel is fully reachable with `Tab` and answerable with `Enter` / `Space`.
- **Stock widgets only** (`Button`, `RadioSet`, `RadioButton`, `Checkbox`, `Input`, `ProgressBar`, `LoadingIndicator`, `Static`, `Markdown`, `Log`, `Tree`, `Tabbed­Content`). No custom-rendered widgets, so screen-reader assistive layers see exactly what Textual ships upstream.
- **CLI fallback is always available.** Pass `-NoTui` (or omit cab-tui entirely) to use Read-Host. Same flow, same prompts, same answers — just rendered line-by-line.

## Troubleshooting

| Symptom | Diagnosis | Fix |
|----|----|----|
| `make setup` runs the legacy CLI even though I ran `make tui-install` | Auto-detect probe failed | Run `python3 -m cab_tui --check` directly to see the error |
| `import cab_tui` fails from outside `cab-tui/` | Editable `.pth` is hidden (Python 3.14 + Hatchling) | `make tui-install` re-runs the unhide; or `chflags nohidden $(python3 -c "import site; print(site.getsitepackages()[0])")/_editable_impl_cab_tui.pth` |
| TUI starts but immediately quits | Terminal is too small (< 80 cols) | Resize and re-run; or use `-NoTui` |
| TUI hangs at "Connected to ca-bootstrap" | Bridge handshake timed out (5s budget) | Press `q` to quit; rerun with `-NoTui`; file an issue with the transcript |
| Bridge dies mid-flow | Python crash; orchestrator falls back to Read-Host with a warning | Check `~/.ca-bootstrap/last-run.log` for the Python traceback |

## How it works

The PowerShell wizard owns all state. cab-tui is a renderer subscribed to a JSON-RPC stream over stdio:

- Parent → child: `welcome`, `step` (start/end/skip), `log`, `progress`, `prompt`, `notify`, `done`
- Child → parent: `ack`, `answer`, `quit`

Wire protocol: line-delimited JSON, UTF-8, no length prefixes. Full message catalog: [`docs/rpc-protocol.md`](rpc-protocol.md).

stdio fd ownership (POSIX, `--rpc` mode): Textual's input driver and the RPC bridge both want fd 0/1, and they collide — Textual would parse the parent's welcome JSON character-by-character, firing the `q` quit binding on words like "Prerequisites". `cab-tui --rpc` resolves this by `dup2`'ing `/dev/tty` onto fds 0/1 so Textual sees the user's controlling terminal, and hands the saved parent-pipe fds to the RPC bridge. Standalone mode (no `--rpc`) leaves stdio alone. Windows is a no-op: there's no `/dev/tty`, and the bridge already disables its consumer cleanly when `connect_read_pipe` fails on `ProactorEventLoop`.

Architecture and widget mapping per phase: [`docs/textual-plan.md`](textual-plan.md).

## Development

```bash
make tui-install                 # editable install + unhide .pth
make tui-test                    # pytest
make test-all                    # Pester + pytest together
```

Layout, widget choices, and the phase plan live in [`docs/textual-plan.md`](textual-plan.md). Wire protocol details in [`docs/rpc-protocol.md`](rpc-protocol.md).
