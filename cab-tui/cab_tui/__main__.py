"""Entry point for `python -m cab_tui` and the `cab-tui` console script."""

from __future__ import annotations

import argparse
import sys

from cab_tui.app import CabTuiApp


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
        from cab_tui.rpc import RpcBridge
        bridge = RpcBridge()
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
