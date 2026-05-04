"""cab-tui — Textual front-end for ca-bootstrap.

The PowerShell side (ca-bootstrap.ps1) is the source of truth for all
state mutations. This package is the presentation layer: it renders
prompts and step status using stock Textual widgets, and forwards the
user's choices back over JSON-RPC.

Phase 1 deliverable: app shell composed entirely from gallery widgets
(Header / Tree / TabbedContent / Log / Footer). No custom widgets.
"""

__version__ = "0.1.0"
