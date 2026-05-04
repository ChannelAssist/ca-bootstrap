"""End-to-end integration tests: real Python child with a real RPC bridge.

Spawns the cab-tui module's RpcBridge in headless mode (no Textual app)
and feeds it a stream of events through real pipes — assert the child's
outbound responses arrive on its stdout.

Distinguished from test_rpc.py which uses in-memory readers/writers.
This catches subprocess-spawning bugs, line-buffering issues, and
encoding mismatches that the unit tests can't.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import textwrap
import time

import pytest


_SRC_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))


def _run_child_script(script: str, stdin_lines: list[str], timeout: float = 5.0) -> tuple[str, str, int]:
    """Spawn `python -c <script>` with the given stdin lines, return (stdout, stderr, returncode)."""
    # Pass src/ via PYTHONPATH so the child can import cab_tui without
    # relying on an editable install (which has been flaky on Python 3.14).
    env = {**os.environ, "PYTHONUNBUFFERED": "1"}
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = _SRC_DIR + (os.pathsep + existing if existing else "")

    proc = subprocess.Popen(
        [sys.executable, "-c", script],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    stdin_blob = ("\n".join(stdin_lines) + "\n").encode("utf-8") if stdin_lines else b""
    try:
        stdout, stderr = proc.communicate(stdin_blob, timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        pytest.fail(f"child timed out; stdout={stdout!r} stderr={stderr!r}")
    return stdout.decode("utf-8"), stderr.decode("utf-8"), proc.returncode


def test_child_acks_welcome_via_real_pipes() -> None:
    """Spawn a Python child, feed welcome, expect ack on stdout."""
    script = textwrap.dedent("""
        import asyncio, sys
        from cab_tui.rpc import RpcBridge

        async def main():
            bridge = RpcBridge()
            async def on_welcome(msg):
                bridge.send_ack("welcome")
                bridge.stop()
            bridge.on("welcome", on_welcome)
            await bridge.start()

        asyncio.run(main())
    """)
    stdout, stderr, rc = _run_child_script(
        script,
        [json.dumps({"type": "welcome", "version": "test", "schema_version": 1})],
    )
    assert rc == 0, f"non-zero exit; stderr={stderr!r}"
    payloads = [json.loads(l) for l in stdout.strip().splitlines() if l]
    assert {"type": "ack", "of": "welcome"} in payloads


def test_child_handles_unicode_round_trip_via_pipes() -> None:
    """Non-ASCII text in an event survives the stdin pipe → handler → stdout."""
    script = textwrap.dedent("""
        import asyncio
        from cab_tui.rpc import RpcBridge

        async def main():
            bridge = RpcBridge()
            async def on_log(msg):
                bridge.send({"type": "echo", "text": msg.raw["text"]})
                bridge.stop()
            bridge.on("log", on_log)
            await bridge.start()

        asyncio.run(main())
    """)
    text = "Émilie Müller — café 漢字 🚀"
    stdout, stderr, rc = _run_child_script(
        script,
        [json.dumps({"type": "log", "text": text}, ensure_ascii=False)],
    )
    assert rc == 0, f"stderr={stderr!r}"
    out = [json.loads(l) for l in stdout.strip().splitlines() if l]
    assert out[0] == {"type": "echo", "text": text}


def test_child_processes_a_burst_of_events_in_order() -> None:
    """Send N events back-to-back; child handler runs once per event in order."""
    script = textwrap.dedent("""
        import asyncio
        from cab_tui.rpc import RpcBridge

        async def main():
            bridge = RpcBridge()
            seen = []
            async def on_step(msg):
                seen.append(msg.raw["step"])
                if len(seen) == 5:
                    bridge.send({"type": "report", "order": seen})
                    bridge.stop()
            bridge.on("step", on_step)
            await bridge.start()

        asyncio.run(main())
    """)
    steps = [f"step-{i}" for i in range(5)]
    stdin_lines = [json.dumps({"type": "step", "step": s}) for s in steps]
    stdout, stderr, rc = _run_child_script(script, stdin_lines)
    assert rc == 0, f"stderr={stderr!r}"
    payloads = [json.loads(l) for l in stdout.strip().splitlines() if l]
    assert any(p.get("type") == "report" and p["order"] == steps for p in payloads)


def test_child_treats_malformed_line_as_fatal_per_protocol() -> None:
    """A garbage line stops the consumer: handler MUST NOT run on the
    trailing valid line, stderr names the parse error, exit is clean
    (the script's main() returns normally after the loop breaks).
    docs/rpc-protocol.md says parse failure is fatal on the receiving
    side — silent recovery would diverge parent and child state."""
    script = textwrap.dedent("""
        import asyncio, sys
        from cab_tui.rpc import RpcBridge

        async def main():
            bridge = RpcBridge()
            count = 0
            async def on_step(msg):
                nonlocal count
                count += 1
                bridge.send({"type": "received", "n": count})
            bridge.on("step", on_step)
            await bridge.start()
            # Surface the fatal flag so the test can assert on it.
            print(f"FATAL_PARSE={bridge._fatal_parse_error}", file=sys.stderr)

        asyncio.run(main())
    """)
    stdin_lines = [
        "this is not json",
        json.dumps({"type": "step", "step": "good"}),
    ]
    stdout, stderr, rc = _run_child_script(script, stdin_lines)
    assert rc == 0, f"stderr={stderr!r}"
    assert "failed to parse" in stderr
    assert "FATAL_PARSE=True" in stderr
    # The on_step handler must NOT have fired for the trailing valid line.
    payloads = [json.loads(l) for l in stdout.strip().splitlines() if l]
    assert all(p.get("type") != "received" for p in payloads), payloads


def test_child_handles_large_payload() -> None:
    """A 256 KB log message survives the pipe → handler → stdout."""
    script = textwrap.dedent("""
        import asyncio
        from cab_tui.rpc import RpcBridge

        async def main():
            bridge = RpcBridge()
            async def on_log(msg):
                bridge.send({"type": "size", "len": len(msg.raw["text"])})
                bridge.stop()
            bridge.on("log", on_log)
            await bridge.start()

        asyncio.run(main())
    """)
    big = "x" * (256 * 1024)
    stdin_lines = [json.dumps({"type": "log", "text": big})]
    stdout, stderr, rc = _run_child_script(script, stdin_lines, timeout=10.0)
    assert rc == 0, f"stderr={stderr!r}"
    payloads = [json.loads(l) for l in stdout.strip().splitlines() if l]
    assert {"type": "size", "len": 256 * 1024} in payloads


def test_child_exits_cleanly_on_eof() -> None:
    """Closing stdin terminates the bridge loop (no pending event)."""
    script = textwrap.dedent("""
        import asyncio
        from cab_tui.rpc import RpcBridge

        async def main():
            bridge = RpcBridge()
            await bridge.start()  # returns when stdin EOFs
            print('clean-exit')

        asyncio.run(main())
    """)
    stdout, stderr, rc = _run_child_script(script, [])
    assert rc == 0, f"stderr={stderr!r}"
    assert "clean-exit" in stdout
