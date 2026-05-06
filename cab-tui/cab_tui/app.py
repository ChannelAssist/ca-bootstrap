"""Phase 1 app shell.

Composed from stock widgets only — no custom subclasses, no rendered
borders we draw ourselves. See docs/textual-plan.md §4 for the full
widget map; this file only sets up the shell + some seed content so
phase 2 can drive it via RPC.
"""

from __future__ import annotations

import asyncio
import sys

from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal
from textual.widgets import (
    Button,
    Checkbox,
    Footer,
    Header,
    Input,
    LoadingIndicator,
    Log,
    MarkdownViewer,
    ProgressBar,
    RadioSet,
    Static,
    TabbedContent,
    TabPane,
    Tree,
)
from textual.widgets.tree import TreeNode

from cab_tui import prompts as _prompts
from cab_tui.rpc import RpcBridge, RpcMessage

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


# Status icons used in the Tree labels. Single-char width so labels
# align even when alternated mid-run.
_STATUS_ICON = {
    "pending": "○",
    "active":  "▶",
    "ok":      "✓",
    "skip":    "↷",
    "warn":    "⚠",
    "fail":    "✗",
}


class CabTuiApp(App):
    """Top-level Textual app. Phase 2: shell + RPC consumer."""

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

    #progress-area {
        height: auto;
    }

    .progress-row {
        height: auto;
        padding: 0 1;
    }

    .progress-label {
        width: 30;
        padding-right: 1;
    }

    .prompt-recovery-details {
        color: $error;
        margin-bottom: 1;
        padding: 0 1;
    }

    .prompt-question {
        width: 100%;
        height: auto;
        padding: 0 1;
        margin-bottom: 1;
    }
    """

    BINDINGS = [
        Binding("q", "quit_with_rollback", "Quit", priority=True),
        Binding("l", "toggle_log",         "Toggle log"),
        Binding("?", "show_help",          "Help"),
    ]

    TITLE = "ca-bootstrap"
    SUB_TITLE = "ChannelAssist developer onboarding"

    def __init__(self, *args, rpc: RpcBridge | None = None, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._rpc = rpc
        self._step_nodes: dict[str, TreeNode[str]] = {}
        # Active prompt id — set when a `prompt` event arrives, cleared
        # when the user submits an answer. Lets button/input handlers
        # know which prompt they're answering.
        self._pending_prompt_id: str | None = None
        # Active progress rows keyed by progress id (one row per repo
        # clone, tool install, etc.). Removed on `done: true`.
        self._progress_rows: dict[str, Horizontal] = {}
        # Set when the parent's `done` event arrives. After that, q-press
        # must self-exit instead of sending a `quit` message: the parent
        # has stopped reading our stdout and is just waiting for the
        # process to terminate.
        self._post_done: bool = False
        # Track the currently-running step so log events from it can
        # populate the Active step body. Without this the body shows
        # the welcome markdown forever — fine when the user is on step
        # 10, but wrong (and confusing) when they advance to 40/60/etc.
        # and the body doesn't reflect what's currently happening.
        self._active_step_id: str | None = None
        # Markdown text shown in #step-body. Reset on every step.start so
        # each step's context is rendered fresh, then appended to via
        # log events. Initial value is the welcome markdown so the
        # first paint matches what the user expects before any RPC
        # event has arrived.
        self._step_body_text: str = _welcome_markdown()
        # Debounce MarkdownViewer updates for high-volume log streams.
        self._step_body_refresh_task: asyncio.Task[None] | None = None

    def compose(self) -> ComposeResult:
        # Standard chrome — Header + Footer get keyboard hint rendering for free.
        yield Header(show_clock=True)

        with Horizontal():
            # Left: Tree of steps. Phase 2 wires status icons (✓ ▶ ○ ✗) via
            # node label updates from journal events.
            tree: Tree[str] = Tree("Steps", id="steps-pane")
            tree.root.expand()
            for step_id, title in SETUP_STEPS:
                node = tree.root.add_leaf(f"{_STATUS_ICON['pending']} {title}", data=step_id)
                self._step_nodes[step_id] = node
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
                    # Progress area: ProgressBar / LoadingIndicator rows
                    # mounted on `progress` RPC events (one row per id).
                    yield Container(id="progress-area")
                    # Prompt area gets populated dynamically when a
                    # `prompt` RPC event arrives; lib/prompts.py mounts
                    # the right widgets per kind.
                    yield Container(id="prompt-area")
                with TabPane("Transcript", id="transcript"):
                    yield Log(highlight=True, id="transcript-log")

        yield Footer()

    # ----- RPC plumbing (phase 2) -----

    async def on_mount(self) -> None:
        if self._rpc is None:
            return
        # Register handlers for the events phase 2 supports. Phase 3 adds
        # `prompt`; phases 5–6 add `progress` and `notify`.
        # Naming note: Textual auto-binds methods named `_on_<message>`
        # to its own internal Message classes (e.g. `_on_notify` ←→ Notify).
        # We use `_handle_rpc_<event>` to avoid those collisions.
        self._rpc.on("welcome", self._handle_rpc_welcome)
        self._rpc.on("step",    self._handle_rpc_step)
        self._rpc.on("log",     self._handle_rpc_log)
        self._rpc.on("notify",  self._handle_rpc_notify)
        self._rpc.on("prompt",  self._handle_rpc_prompt)
        self._rpc.on("progress", self._handle_rpc_progress)
        self._rpc.on("done",    self._handle_rpc_done)
        # Run the consumer concurrently with the UI loop. Observe its
        # completion so a fatal parse error (per protocol) tears the app
        # down with a non-zero exit instead of leaving the UI idle while
        # the parent talks to a child that's stopped reading.
        self._rpc_task = asyncio.create_task(self._rpc.start())
        self._rpc_task.add_done_callback(self._on_rpc_task_done)

    def _on_rpc_task_done(self, task: asyncio.Task) -> None:
        # Fatal parse error → exit non-zero. Normal EOF (parent closed
        # stdin cleanly during shutdown) is fine; we let the host's
        # `done` handler drive the exit code in that case.
        if getattr(self._rpc, "_fatal_parse_error", False):
            print(
                "cab-tui: aborting due to fatal RPC parse error",
                file=sys.stderr,
            )
            self.exit(return_code=2, message="fatal RPC parse error")
            return
        # Surface unexpected task exceptions so they don't get swallowed.
        if not task.cancelled():
            exc = task.exception()
            if exc is not None:
                print(f"cab-tui: RPC consumer crashed: {exc!r}", file=sys.stderr)
                self.exit(return_code=2, message=f"RPC consumer crashed: {exc}")

    # JSON-RPC schema version this TUI knows how to speak. Bumped only on
    # protocol-incompatible changes (renamed event types, restructured
    # prompt shape, etc.). docs/rpc-protocol.md tracks the matrix.
    _SUPPORTED_SCHEMA_VERSION = 1

    async def _handle_rpc_welcome(self, msg: RpcMessage) -> None:
        # Per docs/rpc-protocol.md: child must close on schema_version
        # mismatch instead of acking. Otherwise the parent assumes the
        # child speaks its protocol and may drive an incompatible UI.
        schema = msg.raw.get("schema_version", 0)
        if schema != self._SUPPORTED_SCHEMA_VERSION:
            print(
                f"cab-tui: protocol schema_version mismatch "
                f"(parent={schema}, child supports={self._SUPPORTED_SCHEMA_VERSION}); exiting",
                file=sys.stderr,
            )
            self.exit(return_code=2, message="schema_version mismatch")
            return
        # If the parent shipped its step list (welcome.steps), use it as
        # the source of truth for the Tree pane — supersedes our built-in
        # SETUP_STEPS default. This keeps cab_tui from drifting away
        # from commands/setup.ps1's Get-CABSetupStepDefs whenever the
        # orchestrator renames or reorders a step.
        steps = msg.raw.get("steps") or []
        if steps:
            await self._rebuild_step_tree(steps)
        self._rpc.send_ack("welcome")
        v = msg.raw.get("version", "?")
        self._append_log("info", f"Connected to ca-bootstrap v{v}")

    async def _rebuild_step_tree(self, steps: list) -> None:
        """Rebuild the Tree pane from a list of {id, title} dicts.

        Called when the parent ships its step list in the welcome event.
        Falls back silently on any malformed entry — the static SETUP_STEPS
        default is still mounted from compose() so the user never sees a
        blank tree."""
        try:
            tree = self.query_one("#steps-pane", Tree)
        except Exception:
            return
        # Drop the existing children + node map and rebuild.
        tree.root.remove_children()
        self._step_nodes.clear()
        for entry in steps:
            if not isinstance(entry, dict):
                continue
            step_id = str(entry.get("id", "")).strip()
            title = str(entry.get("title", step_id)).strip() or step_id
            if not step_id:
                continue
            node = tree.root.add_leaf(f"{_STATUS_ICON['pending']} {title}", data=step_id)
            self._step_nodes[step_id] = node
        tree.root.expand()

    async def _handle_rpc_step(self, msg: RpcMessage) -> None:
        step_id = msg.raw.get("step", "")
        node = self._step_nodes.get(step_id)
        if node is None:
            return
        title = self._title_from_node(node)
        phase = msg.raw.get("phase", "")
        if phase == "start":
            node.set_label(f"{_STATUS_ICON['active']} {title}")
            self._append_log("info", f"→ Step start: {step_id}")
            # Reset the step body to a fresh header for the new step.
            # Subsequent log events from this step append below the
            # header so the user sees this step's context inline with
            # any prompt that fires — instead of the previous step's
            # (or step 10's welcome) lingering text.
            self._active_step_id = step_id
            self._step_body_text = f"## {title}\n\n"
            await self._refresh_step_body()
        elif phase == "end":
            status = msg.raw.get("status", "ok")
            icon = _STATUS_ICON.get(status, _STATUS_ICON["ok"])
            node.set_label(f"{icon} {title}")
            details = msg.raw.get("details", "")
            self._append_log("info", f"  Step end: {step_id} — {status}{(' — ' + details) if details else ''}")
            # Leave _active_step_id set so any final log lines from the
            # closing step still land in this step's body rather than
            # bleeding into the next step's empty body. Cleared on the
            # next step.start.
        elif phase == "skip":
            node.set_label(f"{_STATUS_ICON['skip']} {title}")
            self._append_log("info", f"  Step skipped: {step_id}")

    async def _handle_rpc_log(self, msg: RpcMessage) -> None:
        stream = msg.raw.get("stream", "info")
        text = msg.raw.get("text", "")
        self._append_log(stream, text)
        # Mirror the log line into the active step body so descriptive
        # output from steps/*.ps1 (now routed via the Write-Host override
        # in lib/tui-rpc.ps1) is visible inline in the Active step pane
        # alongside any prompt that's about to fire. Without this, every
        # step's "this is what we're about to ask you about" context
        # would only be visible by tabbing to the Transcript pane.
        if self._active_step_id is not None:
            self._step_body_text += (text or "") + "\n"
            self._schedule_step_body_refresh()

    def _schedule_step_body_refresh(self) -> None:
        """Coalesce bursty log events into a single markdown refresh."""
        if self._step_body_refresh_task is not None and not self._step_body_refresh_task.done():
            self._step_body_refresh_task.cancel()

        async def _debounced_refresh() -> None:
            try:
                await asyncio.sleep(0.1)
                await self._refresh_step_body()
            except asyncio.CancelledError:
                return
            finally:
                self._step_body_refresh_task = None

        self._step_body_refresh_task = asyncio.create_task(_debounced_refresh())

    async def _refresh_step_body(self) -> None:
        """Push the current self._step_body_text into the #step-body Markdown.

        Defensively no-ops if the widget isn't mounted yet (early RPC
        events can arrive before compose finishes) or if the underlying
        Markdown.update fails — losing a refresh is annoying but never
        worth crashing the UI loop over.
        """
        try:
            viewer = self.query_one("#step-body", MarkdownViewer)
        except Exception:
            return
        try:
            await viewer.document.update(self._step_body_text)
        except Exception:
            pass

    async def _handle_rpc_notify(self, msg: RpcMessage) -> None:
        # Stock toast — not a custom modal.
        self.notify(
            msg.raw.get("message", ""),
            severity=msg.raw.get("severity", "information"),
            title=msg.raw.get("title", ""),
        )

    async def _handle_rpc_prompt(self, msg: RpcMessage) -> None:
        """A `prompt` event from the parent: render the right widget kind."""
        # Make sure the user can see the prompt by switching to the
        # active-step tab.
        try:
            self.query_one(TabbedContent).active = "step"
        except Exception:
            pass

        prompt_id = str(msg.raw.get("id", ""))
        self._pending_prompt_id = prompt_id

        try:
            area = self.query_one("#prompt-area", Container)
        except Exception:
            self._append_log("error", f"prompt-area not mounted; can't render {prompt_id}")
            return
        await _prompts.render_prompt(area, msg.raw)

    async def _handle_rpc_progress(self, msg: RpcMessage) -> None:
        """A `progress` event: mount/update/remove a ProgressBar or LoadingIndicator.

        Determinate (has `total`): ProgressBar with current/total.
        Indeterminate (no `total`): LoadingIndicator spinner.
        Closing (`done: true`): row is removed.
        """
        pid = str(msg.raw.get("id", ""))
        if not pid:
            return
        try:
            area = self.query_one("#progress-area", Container)
        except Exception:
            return

        if msg.raw.get("done"):
            row = self._progress_rows.pop(pid, None)
            if row is not None:
                try:
                    await row.remove()
                except Exception:
                    pass
            return

        label = str(msg.raw.get("label", ""))
        total = msg.raw.get("total")
        current = msg.raw.get("current", 0)

        existing = self._progress_rows.get(pid)
        if existing is None:
            # First sighting: build a label + bar/spinner row and mount it.
            label_static = Static(label, classes="progress-label", id=f"progress-label-{pid}")
            if total is not None:
                indicator = ProgressBar(
                    total=float(total),
                    show_eta=False,
                    id=f"progress-bar-{pid}",
                )
            else:
                indicator = LoadingIndicator(id=f"progress-spinner-{pid}")
            row = Horizontal(label_static, indicator, id=f"progress-row-{pid}", classes="progress-row")
            await area.mount(row)
            self._progress_rows[pid] = row
            if total is not None:
                indicator.update(progress=float(current))
            return

        # Update existing row.
        if label:
            try:
                lbl = self.query_one(f"#progress-label-{pid}", Static)
                lbl.update(label)
            except Exception:
                pass
        if total is not None:
            try:
                bar = self.query_one(f"#progress-bar-{pid}", ProgressBar)
                bar.update(total=float(total), progress=float(current))
            except Exception:
                pass

    async def _handle_rpc_done(self, msg: RpcMessage) -> None:
        summary = msg.raw.get("summary", "")
        exit_code = int(msg.raw.get("exit_code", 0))
        self._append_log("info", f"=== Done (exit {exit_code}). {summary}")
        # Once `done` arrives, the parent has stopped reading our stdout
        # and is just waiting for us to exit. Pressing `q` after this
        # point must self-exit (see action_quit_with_rollback) — sending
        # another `quit` event would hit a closed read pipe and the
        # parent would never see the keypress.
        self._post_done = True

    # -- helpers --

    def _append_log(self, stream: str, text: str) -> None:
        try:
            log_widget = self.query_one("#transcript-log", Log)
        except Exception:
            return
        log_widget.write_line(text)

    @staticmethod
    def _title_from_node(node: TreeNode[str]) -> str:
        # Strip the leading "X " icon to recover the original title.
        label = str(node.label)
        return label.split(" ", 1)[1] if " " in label else label

    # ----- Prompt answer dispatch (Textual events) -----

    @on(Button.Pressed)
    async def _on_prompt_button(self, event: Button.Pressed) -> None:
        """Catch every prompt button. Routes to the right answer shape
        based on the button id, and clears the prompt area on submit."""
        if not self._pending_prompt_id or self._rpc is None:
            return
        bid = event.button.id or ""

        # confirm: button id encodes the answer value
        confirm_value = _prompts.confirm_value_from_button_id(bid)
        if confirm_value is not None:
            await self._send_answer(confirm_value)
            return

        # recovery: button id encodes retry/skip/quit
        recovery_value = _prompts.recovery_value_from_button_id(bid)
        if recovery_value is not None:
            await self._send_answer(recovery_value)
            return

        # choice / multi / text submit buttons: pick up state from siblings
        if bid == "prompt-choice-submit":
            try:
                rs = self.query_one("#prompt-radioset", RadioSet)
            except Exception:
                return
            value = _prompts.choice_value_from_radio(rs)
            if value is not None:
                await self._send_answer(value)
            return

        if bid == "prompt-multi-submit":
            area = self.query_one("#prompt-area", Container)
            values = _prompts.multi_values_from_checks(area)
            await self._send_answer(values)
            return

        if bid == "prompt-text-submit":
            try:
                inp = self.query_one("#prompt-input", Input)
            except Exception:
                return
            await self._send_answer(inp.value)
            return

    @on(Input.Submitted, "#prompt-input")
    async def _on_prompt_input_submit(self, event: Input.Submitted) -> None:
        """Pressing Enter inside the text Input submits the answer."""
        if not self._pending_prompt_id or self._rpc is None:
            return
        await self._send_answer(event.value)

    async def _send_answer(self, value: object) -> None:
        if self._rpc is None or not self._pending_prompt_id:
            return
        self._rpc.send_answer(self._pending_prompt_id, value)
        self._pending_prompt_id = None
        # Clear the prompt area — the parent will arrange the next step's
        # content via subsequent step/log events.
        try:
            area = self.query_one("#prompt-area", Container)
            await area.remove_children()
        except Exception:
            pass

    # ----- Actions (bound to keys via BINDINGS) -----

    def action_quit_with_rollback(self) -> None:
        # Three lifecycle states matter here:
        #
        # 1. Standalone (no RPC) → exit immediately.
        # 2. Driven by RPC, pre-done → tell the parent we're quitting so
        #    it can run its rollback offer; the parent decides when to
        #    actually close us (via the `done` event).
        # 3. Driven by RPC, post-done → self-exit. The parent has
        #    finished its work and is no longer reading our stdout, so a
        #    `quit` message would never be seen and the user would be
        #    stuck waiting for the dismiss timeout instead of getting
        #    the documented "press q to dismiss" experience.
        if self._rpc is not None and not self._post_done:
            try:
                self._rpc.send_quit()
                self._append_log("warn", "Quit requested — waiting for parent to finish.")
                return
            except Exception:
                pass
        self.exit(message="Quit by user.")

    def action_toggle_log(self) -> None:
        # Switch to the Transcript tab.
        tabs = self.query_one(TabbedContent)
        tabs.active = "transcript" if tabs.active == "step" else "step"

    def action_show_help(self) -> None:
        self.notify(
            "q to quit · l to toggle the transcript · Tab/Enter to navigate prompts. "
            "See docs/tui.md for the full keybinding map.",
            severity="information",
            title="ca-bootstrap TUI",
        )


def _welcome_markdown() -> str:
    """Welcome content rendered before the parent wizard sends its first
    step event. Once the bridge handshake completes, the parent drives
    everything via RPC and this default is replaced by step content.
    Standalone runs (no parent) keep this as the starting view."""
    return """\
# ChannelAssist developer onboarding

This wizard will set up your machine for ChannelAssist development:

- install missing tools (git, gh, .NET 10, Node 20, Python 3.12, Docker, VS Code, optionally WSL2)
- authenticate to GitHub
- create the workspace folder structure
- clone the repos you have access to
- configure your git identity for ChannelAssist commits

Every step is **optional**. Quit any time with `q` or `Ctrl+C`.
"""
