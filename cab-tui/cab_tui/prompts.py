"""Prompt rendering for cab-tui.

Each prompt kind ("confirm" | "choice" | "multi" | "text") maps to a
named Textual widget per docs/textual-plan.md §4. This module owns the
mount/dispatch logic so app.py stays focused on the layout.

When the parent sends a `prompt` event, `render_prompt` mounts the
appropriate widgets into a target container; user interaction triggers
`send_answer` which writes the JSON-RPC `answer` reply via the bridge.
"""

from __future__ import annotations

from typing import Any

from textual.containers import Container, Horizontal
from textual.widgets import Button, Checkbox, Input, Markdown, RadioButton, RadioSet, Static


# Characters that CommonMark / Textual's Markdown widget treat as
# inline-formatting triggers. Escaping these keeps a question like
# "Use default workspace at /Users/peter/_work_/foo?" from rendering
# the segment between underscores in italic, paths containing
# brackets from being parsed as link syntax, etc.
_MD_ESCAPE_CHARS = "\\`*_{}[]()#+-.!|>"


def _md_escape_for_prompt(text: str) -> str:
    """Backslash-escape every Markdown-special char in `text` so it
    renders as literal text in the prompt question widget. Cheap and
    correct: every special char gets a leading backslash, plain ASCII
    passes through untouched."""
    out = []
    for ch in text:
        if ch in _MD_ESCAPE_CHARS:
            out.append("\\")
        out.append(ch)
    return "".join(out)


# ---------- public mount helpers ----------

async def render_prompt(target: Container, prompt: dict[str, Any]) -> None:
    """Replace target's children with widgets for the given prompt event.

    The target is expected to be a Container (e.g. a #prompt-area). We
    don't take an answer callback here; instead the app subscribes to
    Button.Pressed / Input.Submitted etc. and looks up the active
    prompt id from app state. That keeps the answer flow unidirectional
    (UI events → app → bridge) and easy to test in isolation.
    """
    # Clear whatever was previously in the prompt area. await is required
    # because Textual's mount/remove are async.
    await target.remove_children()

    kind = prompt.get("kind", "confirm")
    question = prompt.get("question", "")

    # Question text goes first regardless of kind. We use Markdown
    # rather than Static or Label because both of those rendered the
    # question on a single line in v1.4.1 manual smoke (user reported
    # "Use default workspace at" with the path clipped off):
    #   - Static was rendering single-line in this layout, even with
    #     `width: 100%; height: auto` CSS — the wrapping that should
    #     happen with Rich text didn't take effect inside the
    #     prompt-area Container in real Textual versions.
    #   - Label fixes nothing because it defaults to height: 1 which
    #     overrides our height: auto rule via Textual's CSS specificity.
    # Markdown lays text out as a block-level paragraph that wraps at
    # the widget's width with no fixed height — reliable.
    #
    # We escape Markdown-special chars in the question so paths like
    # "/Users/peter/_work_/foo" don't render the segment between
    # underscores in italic, brackets aren't parsed as link syntax,
    # etc. The escape is conservative — every special char gets a
    # backslash, never the wrong ones.
    await target.mount(
        Markdown(_md_escape_for_prompt(question), classes="prompt-question")
    )

    if kind == "confirm":
        await _mount_confirm(target, prompt)
    elif kind == "choice":
        await _mount_choice(target, prompt)
    elif kind == "multi":
        await _mount_multi(target, prompt)
    elif kind == "text":
        await _mount_text(target, prompt)
    elif kind == "recovery":
        await _mount_recovery(target, prompt)
    else:
        # Unknown kind — render an error so it's visible during dev.
        await target.mount(Static(f"[unknown prompt kind: {kind}]", classes="prompt-error"))


async def _mount_confirm(target: Container, prompt: dict[str, Any]) -> None:
    """Yes/No/Quit buttons via stock `Button` row."""
    options = prompt.get("options") or ["yes", "no", "quit"]
    default = prompt.get("default", "yes")

    # `variant` map gives semantic colors without us styling anything.
    variants = {"yes": "success", "no": "default", "quit": "error"}
    buttons = []
    for opt in options:
        btn = Button(
            opt.capitalize(),
            id=f"prompt-confirm-{opt}",
            variant=variants.get(opt, "default"),
        )
        if opt == default:
            # Focus the default; pressing Enter activates it.
            btn.add_class("prompt-default")
        buttons.append(btn)

    row = Horizontal(*buttons, id="prompt-buttons", classes="prompt-row")
    await target.mount(row)
    # Focus the default button after it's in the tree.
    for b in buttons:
        if "prompt-default" in b.classes:
            b.focus()
            break


async def _mount_choice(target: Container, prompt: dict[str, Any]) -> None:
    """Single-select via stock `RadioSet` + `RadioButton`s."""
    options = prompt.get("options") or []
    default = prompt.get("default")

    radios = []
    for opt in options:
        if isinstance(opt, dict):
            value = str(opt.get("value", ""))
            label = str(opt.get("label", value))
        else:
            value = label = str(opt)
        rb = RadioButton(label, value=(value == default), id=f"prompt-radio-{value}")
        rb.option_value = value  # custom attr; read on submit
        radios.append(rb)

    rs = RadioSet(*radios, id="prompt-radioset")
    await target.mount(rs)

    submit = Button("Continue", id="prompt-choice-submit", variant="primary")
    await target.mount(Horizontal(submit, id="prompt-buttons", classes="prompt-row"))
    submit.focus()


async def _mount_multi(target: Container, prompt: dict[str, Any]) -> None:
    """Multi-select via stock `Checkbox`es."""
    options = prompt.get("options") or []

    checks = []
    for opt in options:
        if isinstance(opt, dict):
            value = str(opt.get("value", ""))
            label = str(opt.get("label", value))
            checked = bool(opt.get("default", False))
        else:
            value = label = str(opt)
            checked = False
        cb = Checkbox(label, value=checked, id=f"prompt-check-{value}")
        cb.option_value = value
        checks.append(cb)

    for cb in checks:
        await target.mount(cb)

    submit = Button("Submit", id="prompt-multi-submit", variant="primary")
    await target.mount(Horizontal(submit, id="prompt-buttons", classes="prompt-row"))
    submit.focus()


async def _mount_text(target: Container, prompt: dict[str, Any]) -> None:
    """Free-text via stock `Input`."""
    default = prompt.get("default") or ""
    placeholder = prompt.get("placeholder", "")

    inp = Input(value=default, placeholder=placeholder, id="prompt-input")
    await target.mount(inp)

    submit = Button("OK", id="prompt-text-submit", variant="primary")
    await target.mount(Horizontal(submit, id="prompt-buttons", classes="prompt-row"))
    inp.focus()


async def _mount_recovery(target: Container, prompt: dict[str, Any]) -> None:
    """Step-failure recovery panel: details Static + Retry/Skip/Quit buttons.

    The question (mounted by render_prompt) doubles as the panel title.
    `details` carries the multi-line failure message.
    """
    details = str(prompt.get("details", ""))
    if details:
        await target.mount(Static(details, id="prompt-recovery-details", classes="prompt-recovery-details"))

    options = prompt.get("options") or ["retry", "skip", "quit"]
    default = prompt.get("default", "retry")

    variants = {"retry": "success", "skip": "default", "quit": "error"}
    buttons: list[Button] = []
    for opt in options:
        btn = Button(
            str(opt).capitalize(),
            id=f"prompt-recovery-{opt}",
            variant=variants.get(opt, "default"),
        )
        if opt == default:
            btn.add_class("prompt-default")
        buttons.append(btn)

    row = Horizontal(*buttons, id="prompt-buttons", classes="prompt-row")
    await target.mount(row)
    for b in buttons:
        if "prompt-default" in b.classes:
            b.focus()
            break


# ---------- answer extraction helpers ----------

def confirm_value_from_button_id(button_id: str) -> str | None:
    """Extract the option value from a confirm-button id."""
    if button_id and button_id.startswith("prompt-confirm-"):
        return button_id[len("prompt-confirm-"):]
    return None


def recovery_value_from_button_id(button_id: str) -> str | None:
    """Extract the option value from a recovery-button id."""
    if button_id and button_id.startswith("prompt-recovery-"):
        return button_id[len("prompt-recovery-"):]
    return None


def choice_value_from_radio(rs: RadioSet) -> str | None:
    """Return the selected option_value from a RadioSet's pressed RadioButton."""
    pressed = rs.pressed_button
    if pressed is None:
        return None
    return getattr(pressed, "option_value", None)


def multi_values_from_checks(target: Container) -> list[str]:
    """Collect all checked Checkbox option_values inside the target."""
    out: list[str] = []
    for cb in target.query(Checkbox):
        if cb.value:
            v = getattr(cb, "option_value", None)
            if v is not None:
                out.append(v)
    return out
