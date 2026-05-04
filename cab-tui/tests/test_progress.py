"""Phase 5: progress event rendering.

Determinate progress (with `total`) → ProgressBar. Indeterminate → LoadingIndicator.
`done: true` removes the row.
"""

from __future__ import annotations

import io

import pytest
from textual.containers import Container
from textual.widgets import LoadingIndicator, ProgressBar, Static

from cab_tui.app import CabTuiApp
from cab_tui.rpc import RpcBridge


def _ack_bridge(captured: io.StringIO) -> RpcBridge:
    return RpcBridge(reader=None, writer_fp=captured)


def _msg(d: dict) -> object:
    class _M:
        def __init__(self, raw):
            self.raw = raw
            self.type = raw.get("type", "")
    return _M(d)


@pytest.mark.asyncio
async def test_progress_with_total_mounts_progress_bar() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "clone-keystone",
            "current": 1, "total": 14, "label": "ChannelAssist/Keystone",
        }))
        await app.workers.wait_for_complete()
        bars = list(app.query(ProgressBar))
        assert len(bars) == 1
        assert bars[0].id == "progress-bar-clone-keystone"
        # total carried through
        assert bars[0].total == 14.0
        # label rendered next to the bar
        lbl = app.query_one("#progress-label-clone-keystone", Static)
        assert "Keystone" in str(lbl.renderable)


@pytest.mark.asyncio
async def test_progress_without_total_mounts_loading_indicator() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "install-docker",
            "label": "Installing Docker Desktop…",
        }))
        await app.workers.wait_for_complete()
        spinners = list(app.query(LoadingIndicator))
        assert len(spinners) == 1
        assert spinners[0].id == "progress-spinner-install-docker"
        # No ProgressBar mounted for the indeterminate case.
        assert len(list(app.query(ProgressBar))) == 0


@pytest.mark.asyncio
async def test_progress_update_advances_existing_bar() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        for current in (1, 5, 14):
            await app._handle_rpc_progress(_msg({
                "type": "progress", "id": "clone-batch",
                "current": current, "total": 14, "label": f"repo {current}",
            }))
            await app.workers.wait_for_complete()
        # Still exactly one bar (subsequent events update, don't re-mount).
        bars = list(app.query(ProgressBar))
        assert len(bars) == 1
        assert bars[0].progress == 14.0
        # Label updated on each tick.
        lbl = app.query_one("#progress-label-clone-batch", Static)
        assert "repo 14" in str(lbl.renderable)


@pytest.mark.asyncio
async def test_progress_done_removes_row() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "clone-keystone",
            "current": 0, "total": 14, "label": "Keystone",
        }))
        await app.workers.wait_for_complete()
        assert len(list(app.query(ProgressBar))) == 1

        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "clone-keystone", "done": True,
        }))
        await app.workers.wait_for_complete()
        # Row gone.
        assert len(list(app.query(ProgressBar))) == 0
        area = app.query_one("#progress-area", Container)
        assert len(list(area.query("Horizontal"))) == 0


@pytest.mark.asyncio
async def test_progress_multiple_concurrent_rows() -> None:
    """Each id gets its own row; they don't collide."""
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        for repo in ("keystone", "cm-shared", "ca-privacy"):
            await app._handle_rpc_progress(_msg({
                "type": "progress", "id": f"clone-{repo}",
                "current": 0, "total": 5, "label": repo,
            }))
            await app.workers.wait_for_complete()
        bars = list(app.query(ProgressBar))
        assert len(bars) == 3
        ids = sorted(b.id for b in bars)
        assert ids == ["progress-bar-clone-ca-privacy",
                       "progress-bar-clone-cm-shared",
                       "progress-bar-clone-keystone"]


@pytest.mark.asyncio
async def test_progress_done_for_unknown_id_is_noop() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        # Should not raise even though we never mounted this id.
        await app._handle_rpc_progress(_msg({
            "type": "progress", "id": "ghost", "done": True,
        }))
        await app.workers.wait_for_complete()
        assert len(list(app.query(ProgressBar))) == 0
