"""End-to-end test: real `app.run()` + real RpcBridge + real OS pipes.

Distinguished from the other integration test:
  * test_integration_handshake.py spawns RpcBridge **without** Textual
    (`headless`). It catches subprocess / encoding / line-buffering bugs
    in the bridge but never exercises the App's input driver.
  * This file spawns the **full** TUI (`python -m cab_tui --rpc`),
    attaches a real PTY for /dev/tty, and asserts the welcome → ack
    handshake completes without Textual stealing the welcome JSON as
    keystrokes.

The bug this guards against: prior to the /dev/tty redirection in
cab_tui/__main__.py, Textual's input driver read fd 0 (the parent's
RPC pipe) and parsed the welcome line character-by-character. The 'q'
in step titles like "Prerequisites" / "20-prereqs" matched the q quit
binding and fired send_quit() before the welcome handler ran. The
parent then saw {"type":"quit"} instead of the expected ack.

Skipped on Windows: the Linux-style PTY setup (setsid + TIOCSCTTY)
doesn't apply, and the Windows path in __main__.py is a no-op anyway
(rpc.py disables the consumer cleanly when connect_read_pipe fails on
ProactorEventLoop). A real Windows TUI bridge needs a separate driver,
tracked elsewhere.
"""

from __future__ import annotations

import fcntl
import json
import os
import pty
import subprocess
import sys
import termios
import threading

import pytest


pytestmark = pytest.mark.skipif(
    sys.platform == "win32",
    reason="PTY ceremony (setsid / TIOCSCTTY) is POSIX-only; the /dev/tty "
           "redirect itself is also a no-op on Windows.",
)


_SRC_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _spawn_with_pty():
    """Spawn cab-tui --rpc with stdin/stdout pipes AND a slave PTY as the
    child's controlling terminal so its os.open('/dev/tty', ...) works.

    Returns (proc, master_fd). Caller closes master_fd and waits/kills proc.
    """
    master_fd, slave_fd = pty.openpty()

    def _make_slave_controlling_tty() -> None:
        # Runs in the child between fork and exec. Becoming a session
        # leader (setsid) detaches us from the parent's controlling
        # terminal, then TIOCSCTTY attaches our slave PTY as the new
        # controlling terminal — which is what /dev/tty resolves to.
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

    env = {
        **os.environ,
        "PYTHONPATH": _SRC_DIR,
        "PYTHONUNBUFFERED": "1",
    }

    proc = subprocess.Popen(
        [sys.executable, "-m", "cab_tui", "--rpc"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        preexec_fn=_make_slave_controlling_tty,
        close_fds=True,
        # Keep slave_fd open in the child so ioctl can attach it. The
        # child doesn't need the fd directly afterwards (it opens
        # /dev/tty), but it must remain open through the ioctl call.
        pass_fds=(slave_fd,),
    )
    # Parent doesn't need slave_fd after the child has it.
    os.close(slave_fd)
    return proc, master_fd


def _drain_pty(master_fd: int, sink: list[bytes]) -> None:
    """Background reader for the slave-PTY output (Textual's rendering).

    Without this, Textual's escape sequences fill the slave-side pipe
    buffer and the child blocks on its first non-trivial render. We
    don't assert against the bytes — they're a side effect — but they
    must be drained.
    """
    try:
        while True:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                return
            if not chunk:
                return
            sink.append(chunk)
    except Exception:
        return


def _read_line_with_timeout(fp, timeout: float) -> bytes | None:
    """Blocking readline on a thread, returns None on timeout."""
    holder: list[bytes] = []

    def _read() -> None:
        try:
            holder.append(fp.readline())
        except Exception:
            holder.append(b"")

    t = threading.Thread(target=_read, daemon=True)
    t.start()
    t.join(timeout=timeout)
    return holder[0] if holder else None


def _kill(proc: subprocess.Popen) -> None:
    for closer in (lambda: proc.stdin.close(), proc.terminate, proc.kill):
        try:
            closer()
        except Exception:
            pass
    try:
        proc.wait(timeout=2.0)
    except Exception:
        pass


def test_welcome_with_q_chars_is_acked_not_quit() -> None:
    """Regression test: the welcome JSON contains 'q' chars in step titles.

    Pre-fix, Textual would parse them as q keystrokes and fire send_quit()
    before _handle_rpc_welcome ran, so the parent received quit instead
    of ack. Post-fix, /dev/tty is the input source — the welcome JSON
    bypasses Textual entirely and reaches the RPC bridge.
    """
    proc, master_fd = _spawn_with_pty()
    pty_sink: list[bytes] = []
    drain = threading.Thread(target=_drain_pty, args=(master_fd, pty_sink), daemon=True)
    drain.start()

    try:
        # Welcome with q chars in BOTH the id and the title — this is the
        # exact shape the orchestrator sends in production (commands/
        # setup.ps1 → Get-CABSetupStepDefs).
        welcome = {
            "type": "welcome",
            "version": "1.4.0",
            "schema_version": 1,
            "command": "setup",
            "steps": [
                {"id": "20-prereqs", "title": "Prerequisites"},
                {"id": "30-gh-auth", "title": "GitHub authentication"},
            ],
        }
        proc.stdin.write((json.dumps(welcome) + "\n").encode("utf-8"))
        proc.stdin.flush()

        line = _read_line_with_timeout(proc.stdout, timeout=5.0)
    finally:
        _kill(proc)
        try:
            os.close(master_fd)
        except Exception:
            pass

    # Diagnostic: capture what the child wrote to stderr in case of failure.
    stderr_data = b""
    try:
        stderr_data = proc.stderr.read() or b""
    except Exception:
        pass

    assert line, (
        f"no response from cab-tui within timeout. "
        f"stderr={stderr_data!r}"
    )
    parsed = json.loads(line.decode("utf-8").rstrip("\n"))
    assert parsed.get("type") == "ack" and parsed.get("of") == "welcome", (
        f"expected ack-of-welcome, got {parsed!r}. "
        f"This regression means Textual is reading the parent's RPC pipe "
        f"as keystrokes again — see _redirect_textual_to_tty in "
        f"cab_tui/__main__.py. stderr={stderr_data!r}"
    )

    # Sanity: stdout (the parent's RPC channel) should NOT contain Textual's
    # ANSI escape sequences. The PTY sink is where rendering bytes belong.
    # We can't assert "stdout has only the ack" cleanly because the child
    # may emit further events between our readline and tear-down, so we
    # just confirm the first line is the ack and trust the bytes that
    # appeared on /dev/tty (pty_sink) carried the rendering.
    assert b"\x1b[" not in line, (
        f"first stdout line contains ANSI escapes — Textual is writing to "
        f"the RPC pipe instead of /dev/tty. line={line!r}"
    )
