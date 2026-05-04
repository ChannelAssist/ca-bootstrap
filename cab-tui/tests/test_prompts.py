"""Phase 3: prompt rendering + answer dispatch.

Each prompt kind in docs/rpc-protocol.md must:
  1. Mount the named widget(s) from docs/textual-plan.md §4
  2. Send a single `answer` reply containing the user's input
"""

from __future__ import annotations

import io
import json

import pytest
from textual.containers import Container
from textual.widgets import Button, Checkbox, Input, RadioButton, RadioSet, Static

from cab_tui.app import CabTuiApp
from cab_tui.rpc import RpcBridge


def _ack_bridge(captured: io.StringIO) -> RpcBridge:
    """RpcBridge with no inbound stream; outbound writes go to `captured`."""
    return RpcBridge(reader=None, writer_fp=captured)


def _last_answer(captured: io.StringIO) -> dict | None:
    """Return the last `answer` JSON in the captured outbound stream."""
    answers = [
        json.loads(l) for l in captured.getvalue().strip().splitlines()
        if l and json.loads(l).get("type") == "answer"
    ]
    return answers[-1] if answers else None


# ---------- confirm prompts (Button row) ----------

@pytest.mark.asyncio
async def test_confirm_prompt_renders_three_buttons() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p1", "kind": "confirm",
            "question": "Continue?", "default": "yes",
            "options": ["yes", "no", "quit"],
        }))
        await app.workers.wait_for_complete()
        buttons = list(app.query("#prompt-area Button"))
        assert len(buttons) == 3
        assert {b.id for b in buttons} == {"prompt-confirm-yes", "prompt-confirm-no", "prompt-confirm-quit"}


@pytest.mark.asyncio
async def test_confirm_prompt_button_press_sends_answer() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test() as pilot:
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p1", "kind": "confirm",
            "question": "Continue?", "default": "yes",
            "options": ["yes", "no", "quit"],
        }))
        await pilot.pause()
        await _press(app, pilot, "#prompt-confirm-no")
        ans = _last_answer(cap)
        assert ans == {"type": "answer", "id": "p1", "value": "no"}


# ---------- choice prompts (RadioSet) ----------

@pytest.mark.asyncio
async def test_choice_prompt_renders_radioset() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p2", "kind": "choice",
            "question": "Pick one",
            "options": [
                {"value": "Y", "label": "Yes"},
                {"value": "n", "label": "No"},
                {"value": "s", "label": "Select"},
            ],
            "default": "Y",
        }))
        await app.workers.wait_for_complete()
        rs = app.query_one(RadioSet)
        radios = list(rs.query(RadioButton))
        assert len(radios) == 3
        assert [getattr(r, "option_value", None) for r in radios] == ["Y", "n", "s"]


@pytest.mark.asyncio
async def test_choice_prompt_submit_sends_selected_value() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test() as pilot:
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p2", "kind": "choice",
            "question": "Pick one",
            "options": [
                {"value": "Y", "label": "Yes"},
                {"value": "n", "label": "No"},
            ],
            "default": "Y",
        }))
        await pilot.pause()
        # Select second radio via the RadioButton's value attribute.
        rb = app.query_one("#prompt-radio-n")
        rb.value = True
        await pilot.pause()
        await _press(app, pilot, "#prompt-choice-submit")
        ans = _last_answer(cap)
        assert ans == {"type": "answer", "id": "p2", "value": "n"}


# ---------- multi prompts (Checkboxes) ----------

@pytest.mark.asyncio
async def test_multi_prompt_renders_checkbox_per_option() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p3", "kind": "multi",
            "question": "Select repos",
            "options": [
                {"value": "keystone",    "label": "Keystone",     "default": True},
                {"value": "cm-shared",   "label": "cm-shared-libs"},
                {"value": "ca-privacy",  "label": "ca-privacy-gate"},
            ],
        }))
        await app.workers.wait_for_complete()
        checks = list(app.query(Checkbox))
        assert [getattr(c, "option_value", None) for c in checks] == ["keystone", "cm-shared", "ca-privacy"]
        # default-true preserved
        assert checks[0].value is True
        assert checks[1].value is False


@pytest.mark.asyncio
async def test_multi_prompt_submit_sends_array_of_checked_values() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test() as pilot:
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p3", "kind": "multi",
            "question": "Select repos",
            "options": [
                {"value": "a", "label": "A"},
                {"value": "b", "label": "B"},
                {"value": "c", "label": "C", "default": True},
            ],
        }))
        await pilot.pause()
        # Toggle a (c starts checked from default=True). Set Checkbox.value
        # directly — Checkbox is a "labeled toggle" and doesn't fire
        # press messages we'd care about for the multi-submit flow.
        cb_a = app.query_one("#prompt-check-a", Checkbox)
        cb_a.value = True
        await pilot.pause()
        await _press(app, pilot, "#prompt-multi-submit")
        ans = _last_answer(cap)
        assert ans is not None and ans["type"] == "answer" and ans["id"] == "p3"
        assert sorted(ans["value"]) == ["a", "c"]


# ---------- text prompts (Input) ----------

@pytest.mark.asyncio
async def test_text_prompt_renders_input_with_default() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test():
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p4", "kind": "text",
            "question": "Custom path?",
            "default": "/tmp/dev",
        }))
        await app.workers.wait_for_complete()
        inp = app.query_one(Input)
        assert inp.value == "/tmp/dev"


@pytest.mark.asyncio
async def test_text_prompt_enter_in_input_sends_answer() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test() as pilot:
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p4", "kind": "text",
            "question": "Custom path?", "default": "",
        }))
        await pilot.pause()
        # Set the input value directly + post a Submitted message.
        inp = app.query_one(Input)
        inp.value = "/tmp/x"
        inp.post_message(Input.Submitted(inp, "/tmp/x"))
        await pilot.pause()
        ans = _last_answer(cap)
        assert ans == {"type": "answer", "id": "p4", "value": "/tmp/x"}


# ---------- behaviour: prompt area cleared after answer ----------

@pytest.mark.asyncio
async def test_prompt_area_cleared_after_answer() -> None:
    cap = io.StringIO()
    app = CabTuiApp(rpc=_ack_bridge(cap))
    async with app.run_test() as pilot:
        await app._handle_rpc_prompt(_msg({
            "type": "prompt", "id": "p1", "kind": "confirm",
            "question": "Continue?", "default": "yes",
            "options": ["yes", "no", "quit"],
        }))
        await pilot.pause()
        await _press(app, pilot, "#prompt-confirm-yes")
        area = app.query_one("#prompt-area", Container)
        # No buttons / question left in the area.
        assert len(list(area.query(Button))) == 0
        assert len(list(area.query(Static))) == 0


# ---------- helpers ----------

async def _press(app, pilot, selector: str) -> None:
    """Trigger a Button.Pressed message on the named button.

    Headless Textual doesn't reliably hit pilot.click(selector); posting
    the message directly is the documented test pattern."""
    btn = app.query_one(selector, Button)
    btn.post_message(Button.Pressed(btn))
    await pilot.pause()


def _msg(d: dict) -> object:
    """Wrap a dict as an RpcMessage-like object with a `.raw` attribute."""
    class _M:
        def __init__(self, raw):
            self.raw = raw
            self.type = raw.get("type", "")
    return _M(d)
