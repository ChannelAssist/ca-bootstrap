"""JSON-RPC over stdio bridge for cab-tui.

The PowerShell wizard (parent) writes line-delimited JSON to our stdin;
we write replies to stdout. See ../../docs/rpc-protocol.md for the
message catalog.

Phase 2 handles: welcome / ack / step / log / done. Phase 3 will add
prompt handling — when a `prompt` event arrives, the app shows the
appropriate widget and the user's choice gets serialized back as an
`answer`.
"""

from __future__ import annotations

import asyncio
import json
import sys
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Optional


@dataclass
class RpcMessage:
    """Parsed inbound message from the parent."""
    raw: dict[str, Any]

    @property
    def type(self) -> str:
        return str(self.raw.get("type", ""))


class RpcBridge:
    """Async stdio bridge.

    Owns the input loop. The hosting App (or test harness) registers
    handlers via `on(event_type, callback)` and calls `start()` to begin
    consuming. Outbound messages go via `send(...)`; the bridge serializes
    and flushes per line.
    """

    def __init__(
        self,
        reader: asyncio.StreamReader | None = None,
        writer_fp = sys.stdout,
    ) -> None:
        self._reader = reader
        self._writer = writer_fp
        self._handlers: dict[str, Callable[[RpcMessage], Awaitable[None]]] = {}
        self._on_unknown: Callable[[RpcMessage], Awaitable[None]] | None = None
        self._stop = asyncio.Event()

    # -- Outbound -----------------------------------------------------------

    def send(self, message: dict[str, Any]) -> None:
        """Serialize and write one message. Blocking write to the configured
        stream; flushed per call so the parent never reads a partial line."""
        line = json.dumps(message, ensure_ascii=False)
        self._writer.write(line + "\n")
        self._writer.flush()

    def send_ack(self, of: str) -> None:
        self.send({"type": "ack", "of": of})

    def send_answer(self, prompt_id: str, value: Any) -> None:
        self.send({"type": "answer", "id": prompt_id, "value": value})

    def send_quit(self) -> None:
        self.send({"type": "quit"})

    # -- Inbound ------------------------------------------------------------

    def on(self, event_type: str, handler: Callable[[RpcMessage], Awaitable[None]]) -> None:
        self._handlers[event_type] = handler

    def on_unknown(self, handler: Callable[[RpcMessage], Awaitable[None]]) -> None:
        self._on_unknown = handler

    async def start(self) -> None:
        """Consume the input stream until EOF or stop()."""
        if self._reader is None:
            self._reader = await self._connect_stdin()
        while not self._stop.is_set():
            try:
                line = await self._reader.readline()
            except asyncio.CancelledError:
                break
            if not line:
                break
            try:
                payload = json.loads(line.decode("utf-8").rstrip("\n"))
            except json.JSONDecodeError as exc:
                # Per spec: parse failure → log to stderr and exit. We
                # only log here; the host decides whether to exit.
                print(f"cab-tui: failed to parse incoming RPC line: {exc!r}", file=sys.stderr)
                continue
            msg = RpcMessage(raw=payload)
            handler = self._handlers.get(msg.type, self._on_unknown)
            if handler is not None:
                await handler(msg)

    def stop(self) -> None:
        self._stop.set()

    @staticmethod
    async def _connect_stdin() -> asyncio.StreamReader:
        loop = asyncio.get_event_loop()
        reader = asyncio.StreamReader()
        protocol = asyncio.StreamReaderProtocol(reader)
        await loop.connect_read_pipe(lambda: protocol, sys.stdin)
        return reader


__all__ = ["RpcBridge", "RpcMessage"]
