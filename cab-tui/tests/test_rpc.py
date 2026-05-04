"""Phase 2: RPC bridge unit tests.

Two layers tested in isolation:
  - RpcBridge wire format (send produces correctly-shaped JSON; the
    bridge parses one inbound line into one RpcMessage; malformed JSON
    is dropped without crashing the loop).
  - End-to-end: feed the bridge a stream of events and assert each
    handler ran with the expected payload, in order.
"""

from __future__ import annotations

import asyncio
import io
import json

import pytest

from cab_tui.rpc import RpcBridge, RpcMessage


@pytest.mark.asyncio
async def test_send_emits_one_line_of_json() -> None:
    out = io.StringIO()
    bridge = RpcBridge(reader=None, writer_fp=out)
    bridge.send({"type": "step", "phase": "start", "step": "10-welcome"})
    line = out.getvalue()
    assert line.endswith("\n")
    parsed = json.loads(line.strip())
    assert parsed == {"type": "step", "phase": "start", "step": "10-welcome"}


@pytest.mark.asyncio
async def test_send_helpers_build_correct_shapes() -> None:
    out = io.StringIO()
    bridge = RpcBridge(reader=None, writer_fp=out)
    bridge.send_ack("welcome")
    bridge.send_answer("step-40-use-default", "yes")
    bridge.send_quit()
    lines = [json.loads(l) for l in out.getvalue().strip().splitlines()]
    assert lines[0] == {"type": "ack", "of": "welcome"}
    assert lines[1] == {"type": "answer", "id": "step-40-use-default", "value": "yes"}
    assert lines[2] == {"type": "quit"}


@pytest.mark.asyncio
async def test_inbound_dispatch_routes_to_handler() -> None:
    received: list[RpcMessage] = []

    async def on_step(msg: RpcMessage) -> None:
        received.append(msg)

    # Feed a single line through a StreamReader.
    reader = asyncio.StreamReader()
    line = (json.dumps({"type": "step", "phase": "start", "step": "10-welcome"}) + "\n").encode()
    reader.feed_data(line)
    reader.feed_eof()

    out = io.StringIO()
    bridge = RpcBridge(reader=reader, writer_fp=out)
    bridge.on("step", on_step)
    await bridge.start()

    assert len(received) == 1
    assert received[0].type == "step"
    assert received[0].raw["step"] == "10-welcome"


@pytest.mark.asyncio
async def test_unknown_event_routes_to_on_unknown() -> None:
    seen: list[str] = []

    async def fallback(msg: RpcMessage) -> None:
        seen.append(msg.type)

    reader = asyncio.StreamReader()
    reader.feed_data((json.dumps({"type": "bonkers"}) + "\n").encode())
    reader.feed_eof()
    bridge = RpcBridge(reader=reader, writer_fp=io.StringIO())
    bridge.on_unknown(fallback)
    await bridge.start()

    assert seen == ["bonkers"]


@pytest.mark.asyncio
async def test_malformed_line_is_fatal_per_protocol(capsys) -> None:
    """docs/rpc-protocol.md: parse failure is fatal — the consumer must
    log the offending bytes and stop, so the host process exits non-zero.
    Continuing past a malformed line would leave the parent thinking we'd
    processed something we silently dropped."""
    received_types: list[str] = []

    async def on_step(msg: RpcMessage) -> None:
        received_types.append(msg.type)

    reader = asyncio.StreamReader()
    reader.feed_data(b"this is not json\n")
    reader.feed_data((json.dumps({"type": "step"}) + "\n").encode())
    reader.feed_eof()
    bridge = RpcBridge(reader=reader, writer_fp=io.StringIO())
    bridge.on("step", on_step)
    await bridge.start()

    err = capsys.readouterr().err
    assert "failed to parse" in err
    # Bridge should have stopped at the malformed line — the trailing
    # well-formed event must NOT have been processed.
    assert received_types == []
    assert bridge._fatal_parse_error is True
