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
import io
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
        writer_fp = None,
        reader_fp = None,
    ) -> None:
        self._reader = reader
        # reader_fp lets the caller hand us a specific input file/fd to
        # consume — used by `cab-tui --rpc` to feed us the parent's pipe
        # after redirecting fd 0 to /dev/tty for Textual's input driver.
        # When None, fall back to sys.stdin (the standalone-app and unit
        # test paths). Resolved lazily inside start() so the value used
        # at startup reflects any sys.stdin reassignment that happened
        # after this RpcBridge was constructed.
        self._reader_fp = reader_fp
        # When writer_fp is None, send() resolves sys.stdout on every
        # call (see line below in send()). That lets a test harness or
        # --rpc redirection that reassigns sys.stdout AFTER this bridge
        # was constructed still be honored, without needing to rebuild
        # the bridge. Pass an explicit writer_fp to pin the destination.
        self._writer = writer_fp
        self._handlers: dict[str, Callable[[RpcMessage], Awaitable[None]]] = {}
        self._on_unknown: Callable[[RpcMessage], Awaitable[None]] | None = None
        self._stop = asyncio.Event()
        # Set when the input loop encounters a malformed line. Per the
        # protocol spec, parse failure is fatal — the host should exit
        # non-zero. Tests inspect this to verify the contract.
        self._fatal_parse_error = False

    # -- Outbound -----------------------------------------------------------

    def send(self, message: dict[str, Any]) -> None:
        """Serialize and write one message. Blocking write to the configured
        stream; flushed per call so the parent never reads a partial line."""
        line = json.dumps(message, ensure_ascii=False)
        writer = self._writer if self._writer is not None else sys.stdout
        writer.write(line + "\n")
        writer.flush()

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
            try:
                self._reader = await self._connect_stdin(self._reader_fp)
            except (io.UnsupportedOperation, OSError, ValueError, NotImplementedError) as exc:
                # No usable stdin. Possible causes:
                #   - test harness has captured it (UnsupportedOperation)
                #   - stdin isn't a pipe / fd unsuitable (OSError, ValueError)
                #   - Windows: the default ProactorEventLoop does not
                #     implement connect_read_pipe for non-socket fds —
                #     raises NotImplementedError. Without this catch,
                #     the bridge would crash on Windows; with it, the
                #     consumer is just disabled (matches the other
                #     no-stdin paths) and outbound `send()` still works.
                # NB: a usable Windows TUI bridge needs a thread-based
                # reader (separate fix); this catch only prevents the
                # crash — the orchestrator's auto-detect probe still
                # uses --check which doesn't need the consumer.
                print(f"cab-tui: stdin unavailable ({exc!r}); RPC consumer disabled", file=sys.stderr)
                return
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
                # docs/rpc-protocol.md: parse failure on either side is
                # fatal — log the offending bytes and stop the consumer
                # so the host process exits non-zero. Continuing would
                # leave the parent thinking we'd processed a message we
                # actually dropped.
                print(
                    f"cab-tui: failed to parse RPC line ({exc}); offending bytes: "
                    f"{line[:200]!r}{'…' if len(line) > 200 else ''}",
                    file=sys.stderr,
                )
                self._stop.set()
                self._fatal_parse_error = True
                break
            msg = RpcMessage(raw=payload)
            handler = self._handlers.get(msg.type, self._on_unknown)
            if handler is not None:
                await handler(msg)

    def stop(self) -> None:
        self._stop.set()

    # Large enough to comfortably hold any plausible RPC message. The
    # default StreamReader limit is 64 KiB, which a long log stream
    # (e.g. a verbose `winget install` chunk) can blow through and
    # crash the bridge with LimitOverrunError. 1 MiB is overkill but
    # cheap.
    _READER_BUFFER_LIMIT = 1024 * 1024

    @staticmethod
    async def _connect_stdin(fp = None) -> asyncio.StreamReader:
        # `fp` overrides sys.stdin when set — used by `cab-tui --rpc` after
        # it dup2's /dev/tty onto fd 0 to give Textual a real terminal.
        # Without the override we'd reach for sys.stdin (which now wraps
        # /dev/tty) and read keystrokes instead of RPC events.
        loop = asyncio.get_event_loop()
        reader = asyncio.StreamReader(limit=RpcBridge._READER_BUFFER_LIMIT)
        protocol = asyncio.StreamReaderProtocol(reader)
        await loop.connect_read_pipe(lambda: protocol, fp if fp is not None else sys.stdin)
        return reader


__all__ = ["RpcBridge", "RpcMessage"]
