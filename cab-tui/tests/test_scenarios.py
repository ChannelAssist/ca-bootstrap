"""Phase 9: scenario tests.

Each test drives the app through a multi-event RPC sequence and asserts
the resulting widget tree matches a golden description. Cheaper than
real Textual snapshot images (no SVG diffs across fonts/terminals) but
catches the same class of regressions: a refactor that quietly drops a
mount, swaps an id, or changes the order of widgets.
"""

from __future__ import annotations

import io

import pytest
from textual.containers import Container
from textual.widgets import Button, LoadingIndicator, ProgressBar, RadioSet, Static

from cab_tui.app import CabTuiApp, SETUP_STEPS
from cab_tui.rpc import RpcBridge


def _bridge() -> tuple[CabTuiApp, io.StringIO]:
    cap = io.StringIO()
    return CabTuiApp(rpc=RpcBridge(reader=None, writer_fp=cap)), cap


def _msg(d: dict) -> object:
    class _M:
        def __init__(self, raw):
            self.raw = raw
            self.type = raw.get("type", "")
    return _M(d)


@pytest.mark.asyncio
async def test_steady_state_after_welcome() -> None:
    """Initial state — welcome handshake complete, no step running."""
    app, _ = _bridge()
    async with app.run_test():
        await app._handle_rpc_welcome(_msg({
            "type": "welcome", "version": "1.4.0",
            "schema_version": 1, "command": "setup",
        }))
        await app.workers.wait_for_complete()

        # 8 step rows in the Tree, all marked pending.
        tree_labels = [str(node.label) for node in app._step_nodes.values()]
        assert len(tree_labels) == len(SETUP_STEPS) == 8
        assert all(label.startswith("○ ") for label in tree_labels), tree_labels

        # No progress, no prompt rendered yet.
        assert len(list(app.query(ProgressBar))) == 0
        assert len(list(app.query(LoadingIndicator))) == 0
        assert len(list(app.query("#prompt-area Button"))) == 0


@pytest.mark.asyncio
async def test_mid_step_state_with_progress_and_log() -> None:
    """Step 60 running, mid-clone: tree shows ▶, progress bar visible, log has lines."""
    app, _ = _bridge()
    async with app.run_test():
        await app._handle_rpc_welcome(_msg({
            "type": "welcome", "version": "1.4.0",
            "schema_version": 1, "command": "setup",
        }))
        await app._handle_rpc_step(_msg({
            "type": "step", "phase": "start", "step": "60-repos",
            "title": "Clone repositories", "ordinal": 6, "total": 8,
        }))
        await app._handle_rpc_log(_msg({
            "type": "log", "stream": "info", "text": "Cloning ChannelAssist/Keystone...",
        }))
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "clone-batch",
            "current": 3, "total": 14, "label": "ChannelAssist/Keystone",
        }))
        await app.workers.wait_for_complete()

        # Tree: step 60 is now active (▶), others still pending (○).
        labels_by_step = {sid: str(app._step_nodes[sid].label) for sid in app._step_nodes}
        assert labels_by_step["60-repos"].startswith("▶ ")
        assert labels_by_step["10-welcome"].startswith("○ ")

        # One progress bar visible; label says Keystone.
        bars = list(app.query(ProgressBar))
        assert len(bars) == 1
        assert bars[0].progress == 3.0 and bars[0].total == 14.0
        details = app.query_one("#progress-label-clone-batch", Static)
        assert "Keystone" in str(details.renderable)

        # No prompt.
        assert len(list(app.query("#prompt-area Button"))) == 0


@pytest.mark.asyncio
async def test_step_completion_clears_progress_and_marks_tree() -> None:
    """Step ends: progress closed (done), tree shows status icon."""
    app, _ = _bridge()
    async with app.run_test():
        await app._handle_rpc_welcome(_msg({
            "type": "welcome", "version": "1.4.0",
            "schema_version": 1, "command": "setup",
        }))
        await app._handle_rpc_step(_msg({
            "type": "step", "phase": "start", "step": "60-repos",
            "title": "Clone repositories", "ordinal": 6, "total": 8,
        }))
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "clone-batch",
            "current": 14, "total": 14, "label": "Done",
        }))
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "clone-batch", "done": True,
        }))
        await app._handle_rpc_step(_msg({
            "type": "step", "phase": "end", "step": "60-repos",
            "status": "ok", "details": "14 cloned",
        }))
        await app.workers.wait_for_complete()

        assert str(app._step_nodes["60-repos"].label).startswith("✓ ")
        assert len(list(app.query(ProgressBar))) == 0


@pytest.mark.asyncio
async def test_recovery_panel_appears_after_step_fail() -> None:
    """Step fails: tree shows ✗, recovery prompt mounts with details."""
    app, _ = _bridge()
    async with app.run_test():
        await app._handle_rpc_welcome(_msg({
            "type": "welcome", "version": "1.4.0",
            "schema_version": 1, "command": "setup",
        }))
        await app._handle_rpc_step(_msg({
            "type": "step", "phase": "start", "step": "60-repos",
            "title": "Clone repositories", "ordinal": 6, "total": 8,
        }))
        await app._handle_rpc_step(_msg({
            "type": "step", "phase": "end", "step": "60-repos",
            "status": "fail", "details": "auth required",
        }))
        # Parent would now ask for recovery — synthesize that.
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "rcv1", "kind": "recovery",
            "question": "Step '60-repos' failed",
            "details": "2 repos failed:\n  Keystone: gh auth required",
            "options": ["retry", "skip", "quit"],
            "default": "retry",
        }))
        await app.workers.wait_for_complete()

        # Tree shows ✗ for the failed step.
        assert str(app._step_nodes["60-repos"].label).startswith("✗ ")

        # Recovery panel: 3 buttons + details Static.
        button_ids = {b.id for b in app.query("#prompt-area Button")}
        assert button_ids == {
            "prompt-recovery-retry", "prompt-recovery-skip", "prompt-recovery-quit"
        }
        details = app.query_one("#prompt-recovery-details", Static)
        assert "Keystone" in str(details.renderable)


@pytest.mark.asyncio
async def test_multiple_concurrent_progress_with_choice_prompt() -> None:
    """Two progress bars + a choice prompt visible simultaneously."""
    app, _ = _bridge()
    async with app.run_test():
        await app._handle_rpc_welcome(_msg({
            "type": "welcome", "version": "1.4.0",
            "schema_version": 1, "command": "setup",
        }))
        # Two installs in flight, plus a choice prompt for the next group.
        for tool in ("docker", "node"):
            await app._handle_rpc_progress(_msg({
                "type": "progress", "id": f"install-{tool}",
                "label": f"Installing {tool}…",
            }))
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "g1", "kind": "choice",
            "question": "Clone all 3 repos?",
            "options": [
                {"value": "Y", "label": "Yes"},
                {"value": "n", "label": "No"},
                {"value": "s", "label": "Select"},
            ],
            "default": "Y",
        }))
        await app.workers.wait_for_complete()

        # Both spinners present.
        spinners = list(app.query(LoadingIndicator))
        assert len(spinners) == 2
        # Plus the RadioSet for choice.
        assert len(list(app.query(RadioSet))) == 1
