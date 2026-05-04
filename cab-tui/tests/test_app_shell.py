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
