# cab-tui

Textual-based terminal UI front-end for ca-bootstrap.

> **Status: shipped in v1.4.0** (all 12 phases of the original plan landed). The PowerShell wizard auto-detects this package and renders `setup` through the TUI when present; falls back to the legacy Read-Host CLI otherwise. The full user-facing guide lives at [`docs/tui.md`](../docs/tui.md).

## Why this exists

`ca-bootstrap setup` was line-by-line `Read-Host` until v1.4.0. The Textual front-end replaces that with a three-pane TUI: persistent step navigation, live progress bars during long-running steps (clones, installs), and structured error recovery (retry / skip / quit on step failure). PowerShell still does all the work; cab-tui is just rendering and event handling subscribed to a JSON-RPC stream over stdio.

See [`docs/textual-plan.md`](../docs/textual-plan.md) for the architecture and [`docs/rpc-protocol.md`](../docs/rpc-protocol.md) for the wire format.

## Install (developer build)

```bash
cd cab-tui
python -m pip install -e '.[dev]'   # binds the install to the current interpreter
```

Requires Python 3.10+. The build-backend is `poetry-core` and `poetry.lock` is committed for reproducibility, but the orchestrator probes the active Python on PATH, so `pip install` (which targets the active interpreter) is the supported install path. `poetry install` would put deps into a Poetry-managed venv that the bridge can't see.

End users don't usually run this directly — `bootstrap.sh` / `bootstrap.ps1` do it automatically when the orchestrator is fetched, and `make tui-install` does it from a clone (the latter also clears the macOS `UF_HIDDEN` flag that Hatchling sets on its editable `.pth` file, which Python 3.14's site.py would otherwise skip).

## Run

```bash
cab-tui --check      # auto-detect probe; exits 0 if cab_tui + textual import cleanly
cab-tui --rpc        # consume JSON-RPC events from stdin (how ca-bootstrap.ps1 invokes us)
cab-tui              # standalone — runs the layout-only app with no parent
```

In normal use, you don't run `cab-tui` directly: `ca-bootstrap.ps1 setup` (or `make setup`) auto-launches it via `python3 -m cab_tui --rpc` over stdio.

## Widget mapping

Every UI element uses a stock widget from the [Textual gallery](https://textual.textualize.io/widget_gallery/). No hand-rolled widgets. The full table is in `docs/textual-plan.md` §4.

| Pane | Widget |
|----|----|
| Steps tree | `Tree` |
| Active step body | `MarkdownViewer` |
| Progress (clones) | `ProgressBar` |
| Progress (installs) | `LoadingIndicator` |
| Confirm prompt | `Button` row |
| Single-pick | `RadioSet` + `RadioButton` |
| Multi-pick | `Checkbox` per option |
| Free text | `Input` |
| Recovery panel | `Static` (details) + `Button` row |
| Transcript | `Log` |
| Toasts | stock `Notify` (no modal) |

## Tests

```bash
cd cab-tui
pytest -q                     # cross-file suite (shell, rpc, integration, prompts, progress, scenarios)
make tui-test                 # equivalent
make test-all                 # Pester (PowerShell side) + pytest together
```

CI runs the suite on ubuntu / macos / windows × Python 3.10 and 3.12. The cross-runtime Pester subset (`tests/lib/tui-rpc.tests.ps1`, `prompts-tui`, `setup-tui-events`, `setup-recovery`) integration-tests the bridge end-to-end with a real Python install.

## Distribution

`bootstrap.sh` / `bootstrap.ps1` install Python 3.10+ if missing and `pip install -e cab-tui/` so first-time users get the TUI by default. Soft fallback to the legacy CLI on any failure; `CA_BOOTSTRAP_NO_TUI=1` opts out entirely. The user-facing distribution story lives in [`docs/tui.md`](../docs/tui.md).
