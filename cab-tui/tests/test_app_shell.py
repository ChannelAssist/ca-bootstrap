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


@pytest.mark.asyncio
async def test_schema_version_mismatch_sets_nonzero_return_code() -> None:
    """Mismatch must propagate through app.return_code so __main__.py exits
    non-zero — otherwise scripts invoking `cab-tui --rpc` see a clean exit
    on protocol error and silently use stale data."""
    import io
    from cab_tui.rpc import RpcBridge

    cap = io.StringIO()
    app = CabTuiApp(rpc=RpcBridge(reader=None, writer_fp=cap))
    async with app.run_test():
        class _M:
            raw = {"type": "welcome", "version": "9.9.9",
                   "schema_version": 99, "command": "setup"}
            type = "welcome"
        await app._handle_rpc_welcome(_M())
        await app.workers.wait_for_complete()
    # Textual's App.exit() stores the requested code in .return_code so
    # __main__.py can pick it up after run() returns.
    assert app.return_code == 2, app.return_code


@pytest.mark.asyncio
async def test_q_press_post_done_self_exits_without_sending_quit() -> None:
    """After `done` arrives, the parent has stopped reading stdout. A
    subsequent `q` keypress must self-exit the TUI, not send another
    `quit` message that the parent will never see (which would leave the
    user waiting for the dismiss-timeout instead of getting the
    documented 'press q to dismiss' experience)."""
    import io
    import json
    from cab_tui.rpc import RpcBridge

    cap = io.StringIO()
    app = CabTuiApp(rpc=RpcBridge(reader=None, writer_fp=cap))
    async with app.run_test():
        # Pre-done: q-press should send `quit` over RPC.
        app.action_quit_with_rollback()
        sent = [json.loads(l) for l in cap.getvalue().splitlines() if l]
        pre_quits = [m for m in sent if m.get("type") == "quit"]
        assert len(pre_quits) == 1

        # Receive `done`.
        class _M:
            raw = {"type": "done", "exit_code": 0, "summary": "8 steps complete."}
            type = "done"
        await app._handle_rpc_done(_M())
        await app.workers.wait_for_complete()
        assert app._post_done is True

        # Post-done: q-press must self-exit. action_quit_with_rollback
        # falls through to app.exit() instead of send_quit.
        cap_before = cap.getvalue()
        app.action_quit_with_rollback()
        cap_after = cap.getvalue()
        # No new `quit` event written.
        new_lines = cap_after[len(cap_before):]
        assert "quit" not in new_lines, new_lines


def test_main_unit_propagates_app_return_code() -> None:
    """`__main__.main()` must return whatever `app.return_code` was set
    to by `app.exit(return_code=...)`. The wired-up app pumps a real
    Textual loop which requires a TTY in subprocess form, so we test
    the propagation logic in-process via a stub app."""
    from cab_tui import __main__ as cab_main

    class _StubApp:
        return_code = 7
        def __init__(self, *args, **kwargs):
            pass
        def run(self) -> None:
            pass

    # Monkey-patch CabTuiApp to our stub for the duration of the call.
    orig = cab_main.CabTuiApp
    cab_main.CabTuiApp = _StubApp
    try:
        # Simulate `cab-tui --rpc`. main() ignores argv when --rpc is set
        # via Namespace; we drive it with a temp argv.
        import sys as _sys
        orig_argv = _sys.argv
        _sys.argv = ["cab-tui", "--rpc"]
        try:
            rc = cab_main.main()
        finally:
            _sys.argv = orig_argv
        assert rc == 7, rc
    finally:
        cab_main.CabTuiApp = orig
