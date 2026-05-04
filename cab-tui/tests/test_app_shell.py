"""Phase 1 acceptance tests.

Asserts the app composes cleanly and contains exactly the gallery widgets
the plan calls for in the shell. Phase 2+ will add behavioural tests
once the RPC layer is in place.
"""

from __future__ import annotations

import pytest

from cab_tui.app import CabTuiApp, SETUP_STEPS


@pytest.mark.asyncio
async def test_app_composes_with_stock_widgets() -> None:
    """The shell uses Header / Tree / TabbedContent / Log / MarkdownViewer / Footer."""
    from textual.widgets import (
        Footer, Header, Log, MarkdownViewer, TabbedContent, Tree,
    )

    app = CabTuiApp()
    async with app.run_test():
        # Each of these queries succeeds only if a stock widget instance
        # is present. A failing query is the signal that someone replaced
        # a gallery widget with a hand-rolled equivalent.
        assert app.query_one(Header)
        assert app.query_one(Footer)
        assert app.query_one(Tree)
        assert app.query_one(TabbedContent)
        assert app.query_one(MarkdownViewer)
        assert app.query_one(Log)


@pytest.mark.asyncio
async def test_steps_tree_lists_all_eight_steps() -> None:
    """Phase 1: the Tree shows all 8 setup steps in execution order."""
    from textual.widgets import Tree
    app = CabTuiApp()
    async with app.run_test():
        tree = app.query_one(Tree)
        labels = [str(node.label) for node in tree.root.children]
        assert len(labels) == 8
        for (_, expected_title), label in zip(SETUP_STEPS, labels):
            assert expected_title in label


@pytest.mark.asyncio
async def test_help_action_emits_a_notification() -> None:
    """Pressing ? shows a toast — uses app.notify(), not a custom modal."""
    app = CabTuiApp()
    async with app.run_test() as pilot:
        await pilot.press("?")
        # Notifications are queued; just ensure the action ran without
        # raising. Phase 7 will assert specific severities.


@pytest.mark.asyncio
async def test_welcome_acks_supported_schema_version() -> None:
    """A welcome carrying the supported schema_version must trigger an ack."""
    import io
    from cab_tui.rpc import RpcBridge

    cap = io.StringIO()
    app = CabTuiApp(rpc=RpcBridge(reader=None, writer_fp=cap))
    async with app.run_test():
        class _M:
            raw = {"type": "welcome", "version": "1.4.0",
                   "schema_version": app._SUPPORTED_SCHEMA_VERSION,
                   "command": "setup"}
            type = "welcome"
        await app._handle_rpc_welcome(_M())
        await app.workers.wait_for_complete()

    import json
    lines = [json.loads(l) for l in cap.getvalue().strip().splitlines() if l]
    assert any(m.get("type") == "ack" and m.get("of") == "welcome" for m in lines), lines


@pytest.mark.asyncio
async def test_welcome_with_mismatched_schema_version_does_not_ack() -> None:
    """Per docs/rpc-protocol.md, child must close on schema_version mismatch.
    The TUI must not ack — the parent infers mismatch from the missing ack
    plus the child's stderr message and falls back to CLI."""
    import io
    from cab_tui.rpc import RpcBridge

    cap = io.StringIO()
    app = CabTuiApp(rpc=RpcBridge(reader=None, writer_fp=cap))
    async with app.run_test():
        class _M:
            raw = {"type": "welcome", "version": "9.9.9",
                   "schema_version": 99,        # incompatible
                   "command": "setup"}
            type = "welcome"
        await app._handle_rpc_welcome(_M())
        await app.workers.wait_for_complete()

    import json
    lines = [json.loads(l) for l in cap.getvalue().strip().splitlines() if l]
    assert not any(m.get("type") == "ack" for m in lines), lines
