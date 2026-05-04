"""Phase 1 app shell.

Composed from stock widgets only — no custom subclasses, no rendered
borders we draw ourselves. See docs/textual-plan.md §4 for the full
widget map; this file only sets up the shell + some seed content so
phase 2 can drive it via RPC.
"""

from __future__ import annotations

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.widgets import (
    Footer,
    Header,
    Log,
    MarkdownViewer,
    TabbedContent,
    TabPane,
    Tree,
)

# The eight setup steps in execution order. Phase 2 will populate this
# from journal events instead of hard-coding it.
SETUP_STEPS: list[tuple[str, str]] = [
    ("10-welcome",       "Welcome"),
    ("40-workspace",     "Workspace location"),
    ("20-prereqs",       "Prerequisites"),
    ("30-gh-auth",       "GitHub authentication"),
    ("50-folders",       "Folder structure"),
    ("60-repos",         "Clone repositories"),
    ("70-git-identity",  "Git identity"),
    ("80-extras",        "Optional extras"),
]


class CabTuiApp(App):
    """Top-level Textual app. Phase 1: layout only."""

    CSS = """
    Screen {
        layers: base;
    }

    #steps-pane {
        width: 35;
        border-right: solid $primary;
    }

    Tree {
        padding: 1;
    }

    Log {
        background: $surface;
    }
    """

    BINDINGS = [
        Binding("q", "quit_with_rollback", "Quit", priority=True),
        Binding("l", "toggle_log",         "Toggle log"),
        Binding("?", "show_help",          "Help"),
    ]

    TITLE = "ca-bootstrap"
    SUB_TITLE = "ChannelAssist developer onboarding"

    def compose(self) -> ComposeResult:
        # Standard chrome — Header + Footer get keyboard hint rendering for free.
        yield Header(show_clock=True)

        with Horizontal():
            # Left: Tree of steps. Phase 2 wires status icons (✓ ▶ ○ ✗) via
            # node label updates from journal events.
            tree: Tree[str] = Tree("Steps", id="steps-pane")
            tree.root.expand()
            for step_id, title in SETUP_STEPS:
                tree.root.add_leaf(f"○ {title}", data=step_id)
            yield tree

            # Right: tabbed content. Active step pane is the default; the Log
            # pane is the live transcript; phase 8 adds a Doctor report tab.
            with TabbedContent(initial="step"):
                with TabPane("Active step", id="step"):
                    yield MarkdownViewer(
                        markdown=_welcome_markdown(),
                        show_table_of_contents=False,
                        id="step-body",
                    )
                with TabPane("Transcript", id="transcript"):
                    yield Log(highlight=True, id="transcript-log")

        yield Footer()

    # ----- Actions (bound to keys via BINDINGS) -----

    def action_quit_with_rollback(self) -> None:
        # Phase 2 will dispatch this through RPC so the PowerShell side
        # offers the same rollback flow that 'q' triggers in the CLI.
        # For phase 1 we just exit; the CLI fallback is the user's safety net.
        self.exit(message="Phase 1 stub — quit-with-rollback lands in phase 6.")

    def action_toggle_log(self) -> None:
        # Switch to the Transcript tab.
        tabs = self.query_one(TabbedContent)
        tabs.active = "transcript" if tabs.active == "step" else "step"

    def action_show_help(self) -> None:
        self.notify(
            "Phase 1 stub. Press q to quit, l to toggle the transcript.",
            severity="information",
            title="ca-bootstrap TUI",
        )


def _welcome_markdown() -> str:
    """Welcome content rendered with MarkdownViewer.

    Phase 1 ships hard-coded text identical to the CLI welcome step; phase 3
    will receive this content via RPC so the two front-ends stay in sync.
    """
    return """\
# ChannelAssist developer onboarding

This wizard will set up your machine for ChannelAssist development:

- install missing tools (git, gh, .NET 10, Node 20, Python 3.12, Docker, VS Code, optionally WSL2)
- authenticate to GitHub
- create the workspace folder structure
- clone the repos you have access to
- configure your git identity for ChannelAssist commits

Every step is **optional**. Quit any time with `q` or `Ctrl+C`.

> **Phase 1 stub.** This is the layout-only build of the TUI. The
> PowerShell wizard does not yet drive it; phase 2 lands the JSON-RPC
> bridge and the prompts will become live.
"""
