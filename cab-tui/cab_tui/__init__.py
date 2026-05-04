"""cab-tui — Textual front-end for ca-bootstrap.

The PowerShell wizard (ca-bootstrap.ps1) is the source of truth for all
state mutations and the orchestrator of the setup flow. This package is
the presentation layer: it renders prompts (confirm / choice / multi /
text / recovery), live progress bars and spinners, the step navigation
tree, and the transcript pane using stock Textual widgets, and forwards
the user's choices back to the wizard over JSON-RPC over stdio. See
``docs/rpc-protocol.md`` for the wire format and ``docs/tui.md`` for
the user-facing guide.

Auto-detected by ``ca-bootstrap.ps1`` when installed; the wizard falls
back to its legacy Read-Host CLI when this package is missing or the
bridge fails to start.
"""

__version__ = "1.4.0"
