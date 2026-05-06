"""Entry point for `python -m cab_tui` and the `cab-tui` console script."""

from __future__ import annotations

import argparse
import os
import sys

from cab_tui.app import CabTuiApp


def _redirect_textual_to_tty() -> tuple[object, object]:
    """Move Textual's I/O off the parent's RPC pipes and onto /dev/tty.

    The parent (ca-bootstrap.ps1) gives us pipes for fd 0 (RPC events
    from parent → child) and fd 1 (RPC replies from child → parent).
    Textual's input driver, however, also reads from fd 0 for keystrokes
    and writes ANSI rendering escapes to fd 1. They collide:

      * Textual parses the parent's welcome JSON character-by-character.
        Every `q` (e.g. in step titles like "Prerequisites" / "20-prereqs")
        fires the quit binding, sending `{"type":"quit"}` to the parent
        before the welcome handler has a chance to ack.

      * Textual's escape sequences corrupt the parent's view of stdout,
        making the JSON-RPC channel unparseable.

    Resolution: dup2 /dev/tty onto fd 0 and fd 1 so Textual sees the
    user's terminal, and hand the saved parent-pipe fds back to the
    caller for the RPC bridge.

    Returns (rpc_in_fp, rpc_out_fp) — file objects wrapping the saved
    pipe fds, ready to pass to RpcBridge as reader_fp / writer_fp.

    Windows is a no-op: there's no /dev/tty, and rpc.py already disables
    the consumer cleanly when connect_read_pipe fails. Returns
    (sys.stdin, sys.stdout) on Windows so the bridge keeps its existing
    behavior. A real Windows TUI bridge needs a separate, thread-based
    driver — tracked separately.
    """
    if sys.platform == "win32":
        return sys.stdin, sys.stdout

    # Save the parent's pipe ends as fresh fds; if anything below fails
    # we close them in the OSError branch to avoid fd leaks.
    rpc_in_fd = os.dup(0)
    rpc_out_fd = os.dup(1)
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
        print(
            f"cab-tui --rpc: cannot open /dev/tty ({exc}); "
            "TUI requires a controlling terminal",
            file=sys.stderr,
        )
        sys.exit(2)

    # Point fd 0 and fd 1 at the terminal. The OLD sys.stdin / sys.stdout
    # Python file objects still wrap fd 0 / fd 1 — after dup2 they now
    # transparently read from / write to /dev/tty, which is exactly what
    # Textual's driver expects.
    os.dup2(tty_fd, 0)
    os.dup2(tty_fd, 1)
    os.close(tty_fd)

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
