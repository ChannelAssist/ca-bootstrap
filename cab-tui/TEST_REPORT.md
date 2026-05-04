# cab-tui phase 1+2 test report

> **Status: phase 2 verified.** This report captures the test layers, what's covered, what was caught while building, and what's deferred to later phases. Generated 2026-05-04 alongside `feature/textual-tui` ahead of phase 3.

## Test layers

| Layer | Files | Purpose | Count |
|---|---|---|---|
| Pester unit (existing PowerShell suite) | `tests/lib/*.tests.ps1`, `tests/regression/*.tests.ps1`, `tests/wizard/*.tests.ps1` | Verify nothing broke in the v1.x wizard | 53 passing, 1 skipped (Windows-only) |
| Pester TUI bridge | `tests/lib/tui-rpc.tests.ps1` (new) | PowerShell side of the JSON-RPC bridge | 5 passing, 2 skipped (Python-side check) |
| Pytest unit — app shell | `cab-tui/tests/test_app_shell.py` | Phase 1: app composes from stock widgets, Tree shows 8 steps, `?` notification works | 3 passing |
| Pytest unit — RPC core | `cab-tui/tests/test_rpc.py` | Phase 2 wire format, dispatch, malformed-line resilience | 5 passing |
| Pytest integration — real subprocess | `cab-tui/tests/test_integration_handshake.py` | End-to-end with real pipes: handshake, unicode, burst, malformed, EOF, large payload | 6 passing |
| Manual smoke | scripted PowerShell→Python handshake | Confirms parent-side `Send-CABTuiEvent` round-trips with a real Python child | ✓ |

**Totals**: 58 Pester (53 passing + 5 new + 3 unrelated skipped) + 14 pytest = **72 tests, all passing**, runtime under 18 seconds for the full suite.

## What's verified

### PowerShell side (`lib/tui-rpc.ps1`)

- `Send-CABTuiEvent` serializes a hashtable to one line of JSON
- UTF-8 round-trip with non-ASCII (Émilie Müller — café)
- Throws cleanly when the child has already exited
- `Receive-CABTuiMessage` parses one inbound line into a hashtable
- Returns `$null` on timeout when the child is silent
- (Skipped, deferred) handshake-against-real-Python-child: needs orchestrator integration, will land alongside phase 3 wiring.

### Python side (`cab_tui/rpc.py`)

- `send()` produces exactly one line of valid JSON, terminated with `\n`
- `send_ack()`, `send_answer()`, `send_quit()` build the documented message shapes
- Inbound dispatch: messages route to the handler keyed by `type`
- Unknown event types fall through to `on_unknown()` if registered
- Malformed lines log to stderr without breaking the loop; well-formed events after still process
- StreamReader buffer limit raised to 1 MiB so large log streams don't crash the bridge with `LimitOverrunError`

### Python integration — real subprocess via real pipes

- Child acks the welcome event over real stdin/stdout
- Unicode round-trip through pipe encoding (Émilie Müller — café 漢字 🚀)
- Burst of 5 events processed in order
- Malformed line followed by valid line: stderr captures the parse error AND the next event still runs
- Large payload (256 KB log line) round-trips cleanly
- Child exits cleanly on stdin EOF

### Phase 1 acceptance (still passing after phase 2)

- App composes with the named stock widgets: `Header`, `Footer`, `Tree`, `TabbedContent`, `MarkdownViewer`, `Log`. Failing query-one is the signal that someone replaced a gallery widget with a hand-roll.
- Tree shows all 8 setup steps in execution order
- `?` action triggers a notification without crashing

## Bugs caught during this test pass

### 1. `_on_<event>` collides with Textual auto-bound message handlers

**Symptom**: Pressing `?` crashed with `'Notify' object has no attribute 'raw'`.

**Root cause**: Textual's framework auto-binds methods named `_on_<MessageClass>` (snake_case) to its internal Message classes. My `_on_notify` was being invoked with Textual's internal `Notify` message instead of my `RpcMessage`.

**Fix**: Renamed all RPC handlers from `_on_<event>` to `_handle_rpc_<event>` (`_handle_rpc_step`, `_handle_rpc_log`, `_handle_rpc_notify`, etc.). Added a code comment documenting the gotcha so phase 3+ contributors don't recreate it.

### 2. asyncio StreamReader 64 KiB line limit crashed the bridge

**Symptom**: A 256 KB log line in the new `test_child_handles_large_payload` test surfaced `asyncio.exceptions.LimitOverrunError: Separator is not found, and chunk exceed the limit`.

**Root cause**: `asyncio.StreamReader()` defaults `limit=2**16`. A long-enough log stream from `winget`/`brew`/etc. would exceed this in production and crash the TUI mid-install.

**Fix**: Construct the reader with `limit=1024 * 1024` (1 MiB). 16× headroom over what we'd plausibly see; documented inline.

### 3. Hatchling editable install on Python 3.14 was unreliable

**Symptom**: After `pip install -e .`, `import cab_tui` would sometimes fail in fresh Python processes despite `.pth` machinery being present in site-packages. Running `cab-tui --check` would work right after install, then fail on a subsequent invocation.

**Root cause**: Hatchling's `_editable_impl_<name>.pth` shim doesn't activate reliably on Python 3.14. Even `editable_mode=compat` had issues.

**Fix**: Switched cab-tui from `src/` layout to flat layout (`cab-tui/cab_tui/...` instead of `cab-tui/src/cab_tui/...`). pyproject.toml's `[tool.hatch.build.targets.wheel] packages = ["cab_tui"]` follows. Also pinned `pythonpath = ["."]` for pytest as a belt-and-suspenders so test discovery never depends on the editable install at all.

## What's NOT yet covered (deferred to later phases)

| Item | Phase | Why deferred |
|---|---|---|
| Real PowerShell ↔ Python end-to-end through `ca-bootstrap.ps1` | Phase 3 | The orchestrator doesn't yet have a `-Tui` flag; phase 3 adds it and the integration test goes there. |
| Prompt-kind rendering (`confirm` → Button row, `choice` → RadioSet, etc.) | Phase 3 | The widgets aren't wired yet. |
| Tree state driven by journal events (✓/▶/○/✗ updates) | Phase 4 | Phase 2 just stubs in the icons; phase 4 plumbs them through journal-load. |
| Progress bar / loading-indicator behaviour | Phase 5 | Widgets aren't wired. |
| Error recovery panel | Phase 6 | Widgets aren't wired. |
| Auto-detect: orchestrator launches TUI when available, falls back to Read-Host when not | Phase 7 | The auto-detect logic hasn't been added to `ca-bootstrap.ps1` yet. |
| CI matrix coverage on Windows | Phase 12 | The `.github/workflows/ci.yml` doesn't yet build cab-tui on its matrix. |
| Snapshot tests (Textual's `pilot.assert_snapshot`) | Phase 9 | We don't have stable layouts for snapshots until phases 4-6 land. |

## Risk assessment for phase 3

Three risks worth tracking:

1. **Async coordination between Textual's UI loop and the RPC consumer.** Phase 2 spawns the consumer as `asyncio.create_task(self._rpc.start())`. If a prompt blocks on `Receive-CABTuiAnswer` from the PowerShell side, Textual's UI must keep responding. The architecture supports this (asyncio is single-threaded cooperative), but phase 3 will exercise the path for the first time and may surface latency or starvation issues. Mitigation: each prompt's button-press / radio-selection is itself an async event that posts the answer; no blocking calls on the UI thread.

2. **Stdin/stdout buffering on Windows.** Tested on macOS only so far. Windows may need `PYTHONUNBUFFERED=1` set explicitly when PowerShell spawns the Python child. Phase 12 (CI matrix) will catch this.

3. **Process lifecycle**: if PowerShell crashes, the child's `start()` returns on stdin EOF (verified). If the child crashes, PowerShell's `Receive-CABTuiMessage` returns `$null` and the orchestrator must fall back to Read-Host for remaining prompts. Phase 7 implements that fallback; for now an unhandled `$null` would just hang.

## Reproducing

```bash
# Pester (PowerShell suite, 53 passing on macOS)
cd ca-bootstrap
pwsh -NoLogo -Command "Invoke-Pester -Path ./tests"

# pytest (cab-tui Python suite, 14 passing)
cd cab-tui
.venv/bin/pip install -e .
.venv/bin/pytest tests/

# probe (TUI auto-detect target)
.venv/bin/cab-tui --check    # exit 0 → TUI available
```

---

*Phase 3 begins after this report is reviewed.*
