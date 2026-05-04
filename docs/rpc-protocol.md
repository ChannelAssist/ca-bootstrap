# ca-bootstrap ↔ cab-tui RPC protocol

Line-delimited JSON over stdio. The PowerShell wizard is the parent process; cab-tui is the child. PowerShell writes events to the child's stdin; the child writes answers / acks to its stdout (the parent's read pipe).

> **Stability**: experimental, breaking changes allowed until v2.0.0. After v2.0.0, the `schema_version` field is bumped on any incompatible change and the parent refuses to drive a child speaking a different version.

## Framing

Every message is a single JSON object on one line, terminated with `\n`. UTF-8 throughout. No multi-line messages, no header frames, no length prefixes — just `\n`-delimited JSON. Both sides flush after each line.

```
{"type":"step","phase":"start","step":"40-workspace","title":"Workspace location"}\n
```

Failure to parse a line is fatal on the receiving side; the failing side logs the offending bytes to its own stderr and exits non-zero.

## PowerShell → cab-tui (events the parent sends)

### `welcome`
Initial banner content. Sent once, immediately after the bridge handshake.
```json
{ "type": "welcome", "version": "1.4.0", "schema_version": 1, "command": "setup" }
```

### `step`
A step begins or ends. `phase` is one of `start` | `end` | `skip`.
```json
{ "type": "step", "phase": "start", "step": "40-workspace", "title": "Workspace location", "ordinal": 2, "total": 8 }
{ "type": "step", "phase": "end",   "step": "40-workspace", "status": "ok", "details": "Created workspace at /tmp/foo" }
```

### `log`
A line of transcript output. Stream is `stdout` | `stderr` | `info` | `warn` | `error`.
```json
{ "type": "log", "stream": "stdout", "text": "Cloning ChannelAssist/Keystone..." }
```

### `progress`
Update or close a progress indicator within the current step. `id` is unique per indicator within a step (so e.g. step 60 can show one progress bar per repo). `current`/`total` are integers; omit `total` for indeterminate spinners.
```json
{ "type": "progress", "id": "clone-keystone", "current": 3, "total": 14, "label": "ChannelAssist/Keystone" }
{ "type": "progress", "id": "clone-keystone", "done": true }
```

### `prompt`
Ask the user a question. The TUI MUST reply with a single `answer` message whose `id` matches.

`kind` is one of:
- `confirm` — yes/no/quit; the TUI renders a `Button` row
- `choice` — single-pick from `options[]`; renders a `RadioSet` of `RadioButton`s
- `multi` — multi-pick; renders `Checkbox`es
- `text` — free-text; renders an `Input`
- `recovery` — step-failure recovery; renders a prominent panel with the failure
  `details` and a `Button` row (Retry / Skip / Quit)

```json
{
  "type": "prompt",
  "id": "step-40-use-default",
  "kind": "confirm",
  "question": "Use default workspace ~/Documents/.../ChannelAssistDev?",
  "default": "yes",
  "options": ["yes", "no", "quit"]
}
{
  "type": "prompt",
  "id": "step-60-docs",
  "kind": "choice",
  "question": "Clone all 3 repos in this group?",
  "options": [
    { "value": "Y", "label": "Yes" },
    { "value": "n", "label": "No (skip group)" },
    { "value": "s", "label": "Select individually" }
  ],
  "default": "Y"
}
{
  "type": "prompt",
  "id": "step-40-custom-path",
  "kind": "text",
  "question": "Custom path (must be absolute):",
  "default": null
}
{
  "type": "prompt",
  "id": "step-60-recovery",
  "kind": "recovery",
  "question": "Step '60-repos' failed",
  "details": "2 repos failed to clone:\n  Keystone: gh auth required",
  "options": ["retry", "skip", "quit"],
  "default": "retry"
}
```

### `notify`
Emit a transient toast. `severity` is one of `information` | `warning` | `error`.
```json
{ "type": "notify", "severity": "warning", "title": "WSL", "message": "Reboot required after install." }
```

### `done`
Setup is finished. The TUI may continue running so the user can review the transcript; `exit_code` is the orchestrator's intended exit.
```json
{ "type": "done", "exit_code": 0, "summary": "8 steps complete; 14 repos cloned." }
```

## cab-tui → PowerShell (replies the child sends)

### `answer`
The user's response to a `prompt`. `id` MUST match the prompt's id. `value` is the chosen string (from `options` for `choice`/`confirm`) or the entered text (for `text`) or an array of selected values (for `multi`).
```json
{ "type": "answer", "id": "step-40-use-default", "value": "yes" }
{ "type": "answer", "id": "step-60-docs",         "value": "Y" }
{ "type": "answer", "id": "step-40-custom-path",  "value": "/Users/peter/dev/ChannelAssistDev" }
```

### `quit`
The user pressed `q` (or Ctrl+C twice). PowerShell receives this and triggers the same rollback offer as the CLI 'q' path.
```json
{ "type": "quit" }
```

### `ack` (optional)
For events where the parent wants confirmation of receipt (rare). Used today only by the handshake.
```json
{ "type": "ack", "of": "welcome" }
```

## Handshake

1. Parent spawns child with stdin/stdout connected.
2. Parent sends `welcome` with schema_version.
3. Child sends `ack` of welcome OR closes if schema_version is incompatible.
4. Parent proceeds to send `step:start` events.

If the parent doesn't see an ack within 5 seconds, it kills the child and falls back to the Read-Host CLI flow.

## Error handling

- Parse failure on either side → log to stderr, exit non-zero.
- Child dies mid-conversation → parent SIGTERMs the child, falls back to Read-Host for the remaining steps, prints a "TUI crashed; continuing in CLI mode" warning.
- Parent dies mid-conversation → child's stdin closes; child shows the last state and lets the user dismiss.

## Phase coverage

Phase 2 implements: `welcome`, `ack`, `step` (start/end), `log`, `quit`. Other event types are reserved here so callers don't have to revisit the protocol when phases 3–6 land.
