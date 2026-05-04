# cab-tui

Textual-based terminal UI front-end for ca-bootstrap.

> **Status: phase 1 of 12.** Layout-only shell composed from stock Textual widgets (Header / Tree / TabbedContent / MarkdownViewer / Log / Footer). The PowerShell wizard does not yet drive the TUI — that's phase 2 (JSON-RPC bridge).

## Why this exists

The interactive `setup` wizard in `ca-bootstrap.ps1` is line-by-line `Read-Host` today. The Textual front-end will replace that with a three-pane TUI that has persistent step navigation, live progress bars during long-running steps, and structured error recovery. The PowerShell side keeps doing all the work; cab-tui is just rendering and event handling.

See [`docs/textual-plan.md`](../docs/textual-plan.md) for the full design.

## Install (developer build)

```bash
cd cab-tui
pip install -e '.[dev]'
```

Requires Python 3.10+. Production install (no dev deps) is `pip install -e .`.

## Run

```bash
cab-tui              # launch the TUI shell
cab-tui --check      # probe — exits 0 if the package + Textual import cleanly
                     # (used by ca-bootstrap.ps1 to auto-detect TUI availability)
python -m cab_tui    # equivalent to `cab-tui` if the script entry isn't on PATH
```

## Widget mapping

Every UI element uses a stock widget from the [Textual gallery](https://textual.textualize.io/widget_gallery/). No hand-rolled widgets. See `docs/textual-plan.md` §4 for the complete table.

## Tests

```bash
cd cab-tui
pytest
```

Phase 1 ships `tests/test_app_shell.py` — verifies the app composes without errors and contains the expected widget types.

## Distribution

For end users (post-v2.0.0), the bootstrap one-liners install Python 3.10+ if needed and `pip install -e cab-tui/`. See plan §7 for the open question on bundling.
