"""Entry point for `python -m cab_tui` and the `cab-tui` console script."""

from __future__ import annotations

import argparse
import os
import sys
from typing import IO, TextIO

from cab_tui.app import CabTuiApp


def _redirect_textual_to_tty() -> tuple[IO[bytes] | None, TextIO | None]:
    """Move Textual's I/O off the parent's RPC pipes and onto /dev/tty.

    The parent (ca-bootstrap.ps1) gives us pipes for fd 0 (RPC events
    from parent → child) and fd 1 (RPC replies from child → parent).
    Textual's LinuxDriver reads keystrokes from fd 0 and — critically —
    writes ALL terminal output (alt-screen entry, rendering, cursor
    moves) to fd 2 (`sys.__stderr__`), NOT fd 1. See
    textual/drivers/linux_driver.py: `self._file = sys.__stderr__`,
    `self.fileno = sys.__stdin__.fileno()`. Both default fds collide
    with the parent's pipe channels:

      * Textual parses the parent's welcome JSON character-by-character.
        Every `q` (e.g. in step titles like "Prerequisites" / "20-prereqs")
        fires the quit binding, sending `{"type":"quit"}` to the parent
        before the welcome handler has a chance to ack.

      * Textual's escape sequences go to fd 2 (parent's stderr pipe),
        which the parent dutifully captures into the journal — but
        never echoes back to the user's terminal. End result: the user
        sees the PowerShell banner, the alt-screen never appears, and
        every interactive `make setup` looks like it froze. The handshake
        completes (so the orchestrator says `Using TUI`), the bridge
        consumer keeps processing events, but the visible TUI is empty.

    Resolution: dup2 /dev/tty onto fd 0 (keystroke input) and fd 2
    (Textual rendering output). fd 1 stays untouched — pointing at the
    parent's stdout pipe — which is what we want for the RPC reply
    channel. The bridge gets a dup'd handle to fd 1 (rpc_out_fd) so
    there's no Textual rendering racing for that channel.

    Returns:
        (rpc_in_fp, rpc_out_fp) — file objects wrapping the saved pipe
        fds, ready to pass to RpcBridge as `reader_fp` / `writer_fp`.
        `rpc_in_fp` is opened in binary mode (asyncio's StreamReader
        decodes bytes → str itself); `rpc_out_fp` is utf-8 text mode.

    Windows is a no-op: there's no /dev/tty, and rpc.py already disables
    the consumer cleanly when connect_read_pipe fails. Returns
    `(None, None)` so RpcBridge falls back to sys.stdin / sys.stdout
    via its own None-handling — same runtime behaviour as before, with
    a more honest type signature. A real Windows TUI bridge needs a
    separate, thread-based driver — tracked separately.
    """
    if sys.platform == "win32":
        return None, None

    # Save the parent's pipe ends as fresh fds; if anything below fails
    # we close them in the OSError branch to avoid fd leaks. saved_stderr_fd
    # is for re-binding sys.stderr after the fd 2 redirect so Python-side
    # tracebacks and `print(..., file=sys.stderr)` from the child still
    # reach the parent's transcript (~/.ca-bootstrap/last-run.log) — see
    # the rebind below for the full reasoning.
    rpc_in_fd = os.dup(0)
    rpc_out_fd = os.dup(1)
    saved_stderr_fd = os.dup(2)
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR)
    except OSError as exc:
        # No controlling terminal (CI, headless, daemon under systemd).
        # We can't run a TUI without one — exit cleanly so the parent
        # gets a non-zero exit and falls back to its CLI path. The
        # process-wide stdio is still wired to the parent's pipes here,
        # so writing to stderr reaches the parent's transcript.
        os.close(rpc_in_fd)
        os.close(rpc_out_fd)
        os.close(saved_stderr_fd)
        print(
            f"cab-tui --rpc: cannot open /dev/tty ({exc}); "
            "TUI requires a controlling terminal",
            file=sys.stderr,
        )
        sys.exit(2)

    # Point fd 0 (input) and fd 2 (output) at the terminal. Textual's
    # LinuxDriver reads keystrokes from sys.__stdin__.fileno() (= fd 0)
    # and writes ALL terminal output — alt-screen entry, rendering,
    # cursor moves — to sys.__stderr__ (= fd 2). It does NOT use fd 1.
    # See textual/drivers/linux_driver.py: `self._file = sys.__stderr__`,
    # `self.fileno = sys.__stdin__.fileno()`.
    #
    # So fd 1 stays untouched — pointing at the parent's stdout pipe —
    # which is exactly what we want: the bridge writes RPC replies via
    # rpc_out_fd (a dup of fd 1) and there's no Textual rendering racing
    # for that channel. fd 2 → /dev/tty makes Textual visible to the user.
    os.dup2(tty_fd, 0)
    os.dup2(tty_fd, 2)
    os.close(tty_fd)

    # Re-bind sys.stderr to write to the saved parent-pipe fd so child
    # diagnostics still reach ~/.ca-bootstrap/last-run.log:
    #
    #   - sys.__stderr__ was captured at interpreter startup and wraps
    #     a FileIO bound to fd 2. After dup2(tty_fd, 2) above, that
    #     FileIO writes to /dev/tty — which is exactly what Textual
    #     wants for its rendering channel.
    #   - But sys.stderr (the canonical name Python's traceback machinery
    #     and most user code write to) is the SAME object by default, so
    #     it was about to write tracebacks to /dev/tty too — invisibly
    #     overlaid on Textual's screen, and lost to the transcript.
    #
    # Solution: leave sys.__stderr__ alone (Textual relies on it) and
    # rebind sys.stderr to a fresh wrapper around the saved pipe fd.
    # Now traceback.print_exc(), `print("oops", file=sys.stderr)`, and
    # similar diagnostics flow back to the orchestrator's stderr pipe
    # → last-run.log, while Textual's rendering keeps owning fd 2.
    #
    # `errors="backslashreplace"` (NOT "strict"!) so the error-reporting
    # channel can't itself raise. A traceback containing a surrogate-
    # escape from `os.fsdecode` of an undecodable filename, or an env
    # var with non-UTF-8 bytes, would trip a strict encoder and silence
    # the very diagnostic we're trying to surface. backslashreplace
    # encodes those bytes as visible `\xNN` escapes — readable, and
    # impossible to fail-encode. (rpc_out_fp above stays "strict" —
    # the JSON-RPC wire format pins UTF-8 and a bad encoding there
    # SHOULD fail loudly rather than send garbage to the parent.)
    sys.stderr = os.fdopen(
        saved_stderr_fd,
        "w",
        buffering=1,
        encoding="utf-8",
        errors="backslashreplace",
    )

    # Hand the saved fds back as Python files for the RPC bridge.
    # Binary read for the bridge's asyncio StreamReader (it expects an
    # object with fileno()); line-buffered text write for outbound
    # messages (matches the parent's line-delimited expectation).
    # Explicit utf-8 encoding because docs/rpc-protocol.md pins the wire
    # format as UTF-8 JSON — Python's default text-mode encoding is
    # locale-dependent (cp1252 on a default Windows install, etc.),
    # which would silently mangle non-ASCII payloads on misconfigured
    # hosts. errors='strict' converts a bad encoding into a loud
    # exception instead of a quiet replacement character.
    rpc_in_fp = os.fdopen(rpc_in_fd, "rb", buffering=0)
    rpc_out_fp = os.fdopen(
        rpc_out_fd, "w", buffering=1, encoding="utf-8", errors="strict"
    )
    return rpc_in_fp, rpc_out_fp


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="cab-tui",
        description=(
            "Textual TUI for ca-bootstrap. Subscribes to a JSON-RPC stdio "
            "stream from ca-bootstrap.ps1 and renders the interactive setup "
            "flow with stock Textual widgets (Tree, ProgressBar, "
            "LoadingIndicator, RadioSet, Button row, etc.). See docs/tui.md."
        ),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Probe whether the TUI can start (used by ca-bootstrap.ps1 "
             "to decide between TUI and Read-Host fallback). Exits 0 on success.",
    )
    parser.add_argument(
        "--rpc",
        action="store_true",
        help="Run as a child of ca-bootstrap.ps1, consuming JSON-RPC events "
             "over stdin and emitting answers on stdout. See "
             "docs/rpc-protocol.md for the message catalog.",
    )
    args = parser.parse_args()

    if args.check:
        # Don't actually launch; just confirm the package + Textual import
        # cleanly. This is the orchestrator's auto-detect probe.
        import textual  # noqa: F401
        print(f"cab-tui ok (textual {textual.__version__})")
        return 0

    if args.rpc:
        # Redirect Textual's I/O to /dev/tty so it doesn't fight the RPC
        # bridge for the parent's pipes. See _redirect_textual_to_tty
        # for the failure mode this prevents.
        rpc_in_fp, rpc_out_fp = _redirect_textual_to_tty()
        from cab_tui.rpc import RpcBridge
        bridge = RpcBridge(reader_fp=rpc_in_fp, writer_fp=rpc_out_fp)
        app = CabTuiApp(rpc=bridge)
        app.run()
        # Respect the app's exit code — schema_version mismatch and fatal
        # RPC parse errors call self.exit(return_code=2). Returning 0 here
        # would mask protocol errors as successful runs to the parent
        # orchestrator and to scripts invoking `cab-tui --rpc`.
        return int(getattr(app, "return_code", 0) or 0)

    app = CabTuiApp()
    app.run()
    return int(getattr(app, "return_code", 0) or 0)


if __name__ == "__main__":
    sys.exit(main())
