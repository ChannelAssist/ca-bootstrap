# ca-bootstrap v2.0.0-alpha.4 — implementation spec

- **Date:** 2026-05-28
- **Author:** Peter Giannopoulos + Claude Code (AI-assisted drafting)
- **Status:** Accepted — implemented and tested (20/20 acceptance + unit coverage)
- **Work item:** [AB#40188](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/40188) — alpha.4 spec + plan PBI (child of Epic AB#38056)
- **Builds on:** [alpha.1 spec](2026-05-25-go-v2-0-alpha-1-spec.md), [alpha.2 spec](2026-05-25-go-v2-0-alpha-2-spec.md), [alpha.3 spec](2026-05-25-go-v2-0-alpha-3-spec.md), [pivot doc](2026-05-25-go-rewrite-pivot.md)
- **Reference (PS-era parity target):** [`legacy/commands/undo.ps1`](../../legacy/commands/undo.ps1)

## 1. TL;DR

`v2.0.0-alpha.4` adds `ca-bootstrap undo` — walks the action journal in reverse and dispatches each reversible entry to a per-action reverser. Closes phase D of the pivot roadmap (alpha.3 shipped `repair --target`; alpha.4 ships `undo`). **Scope-limited to the action types alpha.1–3 actually emit**: `identity_set` (the workspace `.git/config` writer in alpha.2) and `install_success` (the tool installer in alpha.3). Other PS-era reversers (clone_repo, create_folder, seed_readme, etc.) ship alongside the alphas that introduce their producing actions. Introduces journal entry IDs (currently missing) so an append-only `entry_undone` marker can cross-reference the original entry without mutating prior NDJSON lines.

## 2. Decisions

### 2.A — Carried from prior alphas (no change)

Repo layout, binary name (`ca-bootstrap`), versioning (`v2.0.0-alpha.N`), manifest format (YAML in `internal/manifest/`), telemetry (none ever), code signing (defer to v2.0.0 final), TUI (none), dependencies (cobra, yaml.v3, stdlib only — adding any requires explicit rationale), session-lock semantics (alpha.3 §6 carries forward; `undo` acquires the lock).

### 2.B — Locked via brainstorming (pending Peter confirmation — date TBD)

| # | Decision | Choice | Notes |
|---|---|---|---|
| 1 | **alpha.4 scope** | `undo` for action types alpha.1–3 emit only | Two reversers (`identity_set`, `install_success`). Per-feature reversers land in the alpha that introduces the feature — see §9. Smallest discipline gate; parallels alpha.3 (`repair --target` only). |
| 2 | **Append-only marker, not entry mutation** | Append a new `entry_undone` entry that references the reversed entry by `id` | Direct mutation of prior NDJSON lines is incompatible with append-only journaling. The PS-era `Set-CABEntryUndone` model (which mutates a YAML doc in place) does not port. Trade-off: undo state lives across multiple journal lines and must be reconstructed by the reader — acceptable given how rarely the journal is read. |
| 3 | **Tool uninstall is opt-in via `--include-tools`** | Default = leave installed tools alone; flag opts in per-tool | Matches PS-era. Rationale: other projects on the developer machine may depend on those tools. Per-tool interactive confirmation when the flag is set; per-tool answer key (`undo.uninstall.<tool-id>`) for unattended runs. |
| 4 | **Unattended `undo` requires `--force`** | Same as PS-era. Without `--force`, `-Unattended` undo exits 1 with "use --force to confirm" | Reversing changes is destructive; refusing the default safety net in CI/automation must be explicit. |

### 2.C — Autonomous calls (lower stakes — flagged for redirect if needed)

| # | Decision | Choice | Reasoning |
|---|---|---|---|
| 5 | **Entry IDs** | Add `Entry.ID string` field; populated at `Append` time by the journal package (random hex, 10 bytes, same scheme as `SessionID`); `omitempty` so existing alpha.1–3 NDJSON lines remain backwards-readable | Existing entries without an `id` are considered legacy and ineligible for undo (see §7.4). Production journals from alpha.1–3 only existed on developer machines during alpha development; no real user impact. |
| 6 | **Legacy entries (pre-alpha.4)** | Skip — print `info` line, do not error | An entry without `id` cannot be marked undone safely. Better to skip than error out, since these only exist in pre-alpha.4 dev journals. |
| 7 | **`--target` taxonomy** | `--target identity` (matches `identity_set`), `--target tools` (matches `install_success`), `--target tool:<id>` (matches `install_success` with `Target: <id>`) | Mirrors the alpha.3 `repair --target <id>` model. Future alphas extend the table as new action types land. |
| 8 | **Audit snapshot** | Copy `journal.ndjson` to `journal.ndjson.undone-<ISO8601>` after the run | PS-era convention; cheap (one file copy), valuable for "what happened?" forensics. Failure to snapshot is `warn`, not `fail` — primary journal already records the undo via `entry_undone`. |
| 9 | **Walk order** | File order, reversed | NDJSON is append-only, so file order = chronological. No need to sort by timestamp or ID. |
| 10 | **`entry_undone` for failed reversers** | Only emit on successful reversal | A failed reverser leaves state inconsistent; emitting `entry_undone` would lie. Failed reversers are reported in the run summary and reflected in exit code 7. |
| 11 | **`--ForceUnlock`** | Same as alpha.3 — carry forward verbatim | The lock-handling code is shared; `undo` honors the same flag. |
| 12 | **Exit codes** | `0` = success (incl. nothing to reverse), `1` = system error (lock held, manifest, IO), `7` = at least one reverser failed, `130` = user quit at confirmation prompt | `7` mirrors PS-era; distinct from `1` so CI can branch on partial-failure vs. infra-failure. |
| 13 | **Interactive confirmation** | One up-front "proceed with reversal?" (default `no`), plus per-tool confirmation when `--include-tools` is set | Matches PS-era. The up-front confirm is the headline safety check; the per-tool confirm exists because uninstalls are the most destructive class. |
| 14 | **Verifying state before reversing** | Each reverser checks current state and returns `noop`/`skip`/`refused` rather than blindly running the reverse command | E.g., if a tool is already uninstalled by hand, `Invoke-CABUndoToolInstall` returns `noop` — symmetric with PS-era. |

## 3. Non-goals (explicitly OUT of alpha.4)

- Reversers for actions that don't yet exist in the Go journal — those land with their producing alphas (see §9).
- `undo --dry-run` (beta.1 or later).
- `undo --interactive` (per-entry confirmation across all categories). The single up-front confirm + per-tool confirm is alpha.4's UX.
- Retry-on-failure / multi-pass reversal.
- Reversing previously-undone entries (no "redo").
- Multi-machine journal merging.
- Audit-snapshot rotation or compaction. The `.undone-<ts>` files accrue; cleanup is the operator's responsibility for alpha.4. Defer to v1.0.
- Reversing alpha.3's `install_failed` / `install_skipped` / `manual_install_required` / `install_attempt` entries. They are bookkeeping; no state to reverse.
- `entry_undone` for `session_start` / `session_end` / step-result markers. Categorical bookkeeping, not state changes.

## 4. Architecture additions on top of alpha.3

### 4.1 New Go packages

```
internal/undo/
    undo.go                     // Run(opts) orchestrator
    undo_test.go
    reversers/
        identity.go             // reverses identity_set
        identity_test.go
        tool_install.go         // reverses install_success
        tool_install_test.go
```

### 4.2 Updates to existing packages

- `internal/journal/entry.go`: add `ID string` field (`json:"id,omitempty"`). Marshals at the front (after `ts`) for readability.
- `internal/journal/journal.go`: populate `Entry.ID` at `Append` time when missing; add `func Read(path string) ([]Entry, error)` (parse the NDJSON file, return all entries — undo's only reader). Single-pass; the journal is small (one line per action; alpha.1–3 sessions produce <20 lines/run).
- `internal/cli/`: new `undo.go` with the Cobra command, flag wiring, and the call into `internal/undo`.
- `internal/cli/root.go`: register `undo` as a subcommand.
- `internal/install/`: new `Uninstall(method, id string) error` mirror of the install-dispatch — accepts the same `method` values written by alpha.3 (`winget`, `brew`, `apt`, `dnf`, `snap`, `npm`).
- `internal/identity/identity.go`: new `RestoreWorkspaceIdentity(workspace, name, email string) error` — if both `name` and `email` are empty, remove the workspace `.git/config` `[user]` block entirely; otherwise overwrite with the supplied values.

### 4.3 No new external dependencies

Same constraint as alpha.1–3. The `Uninstall` dispatch is `exec.Command` over the same package managers already invoked by `internal/install/install_{unix,windows}.go`.

## 5. Functional spec — `undo`

### 5.1 Behavior — interactive mode

```text
$ ca-bootstrap undo
ca-bootstrap undo

  Reversible actions found:
    [identity] 1 action(s)
    [tools]    2 action(s)        ← only shown when --include-tools is set

  Proceed with reversal (each destructive action will be re-confirmed)? [y/N/q]: y

  [1/1] undo identity_set [a1b2c3d4...]
        ✓ Restored previous user.name / user.email in workspace .git/config

  ✓ 1 reversed, 0 skipped
    Journal snapshot: ~/.ca-bootstrap/journal.ndjson.undone-2026-05-28T14-30-00Z
```

Default (no flags): tools are listed for situational awareness but **not reversed** unless `--include-tools` is also passed. The up-front prompt defaults to `no` (capital-N hint).

### 5.2 Behavior — `--target` scope

```text
$ ca-bootstrap undo --target identity
```

Only entries matching the target are considered. Targets:

| Target | Matches |
|---|---|
| `identity` | Action `identity_set` |
| `tools` | Action `install_success` (requires `--include-tools` to actually run; otherwise: "use `--include-tools` to uninstall") |
| `tool:<id>` | Action `install_success` AND `Target == <id>` |

Unknown targets exit 1 with `no reversible actions match target '<x>'`.

### 5.3 Behavior — `--include-tools`

Without this flag, `install_success` entries are listed but not reversed. With it, each tool prompts individually:

```text
  Uninstall dotnet-10? Other projects may depend on it. [y/N/q]: n
        - dotnet-10 install kept (declined)
```

Answer key `undo.uninstall.<tool-id>` controls per-tool consent in unattended mode.

### 5.4 Behavior — unattended

```text
$ ca-bootstrap undo --unattended --config-file answers.yaml --force
```

`--force` is required. Without it: exit 1, message `"--force is required to undo non-interactively (refusing to reverse changes without explicit confirmation)"`. With it: skip the up-front confirm, but still honor per-tool `undo.uninstall.<tool-id>` answers when `--include-tools` is set.

Answer-file additions:

```yaml
undo:
  proceed: true
  uninstall:
    dotnet-10: false
    node-20:   false
```

### 5.5 Exit codes

| Code | Meaning |
|---|---|
| `0` | All applicable reversers succeeded, or nothing reversible found. |
| `1` | System error: lock held without `--ForceUnlock`, journal unreadable, IO failure unrelated to a specific reverser. Also: `--unattended` without `--force`. Also: `--target <x>` with no matches. |
| `7` | One or more reversers failed; others may have succeeded. Run summary lists which. |
| `130` | User quit at the up-front prompt OR at a per-tool prompt. |

### 5.6 The `--ForceUnlock` flag

Same semantics as alpha.3 (spec §5.5). Carried forward for `undo`'s session-lock acquisition.

## 6. Functional spec — journal extensions

### 6.1 `Entry.ID`

New field. Populated at `Append` time by `journal.Session.write` when not already set:

```go
type Entry struct {
    ID        string            `json:"id,omitempty"`
    TS        time.Time         `json:"ts"`
    SessionID string            `json:"sessionID"`
    Action    string            `json:"action"`
    Target    string            `json:"target,omitempty"`
    Before    map[string]string `json:"before,omitempty"`
    After     map[string]string `json:"after,omitempty"`
    Result    string            `json:"result"`
}
```

ID scheme: same `newID()` helper currently used for `Session.ID` — 10 bytes of crypto-random, hex-encoded → 20 chars. Distinguishable from sessionID by context (entries have both; sessions have only one).

### 6.2 `entry_undone` marker

Appended on successful reversal:

```json
{"id":"...","ts":"...","sessionID":"...","action":"entry_undone","target":"<reversed entry's id>","result":"ok"}
```

`target` carries the ID of the entry being marked as reversed. Future `undo` runs skip any entry whose ID appears as the `target` of a later `entry_undone` entry — implemented by a single pass that builds a set of reversed IDs from the file, then a second pass that filters the reversible set.

### 6.3 Audit snapshot

After the run completes, `journal.ndjson` is copied to `journal.ndjson.undone-<ISO8601>` (UTC, colons replaced with hyphens to keep the filename Windows-safe). Failure is warned, not failed — the primary record (the `entry_undone` lines in the live journal) already exists.

### 6.4 Legacy entry handling

An entry without an `id` field (pre-alpha.4) is skipped with an `info`-level line:

```
  ⓘ Skipping legacy entry (no id): identity_set [2026-05-26T12:34:56Z]
```

Counted as `skipped` in the summary; no exit-code penalty. Production users do not have pre-alpha.4 journals (no release shipped before alpha.1).

## 7. Functional spec — per-action reversers

Only two reversers ship in alpha.4 (per §2.B.1). Each lives in `internal/undo/reversers/`.

### 7.1 `identity_set` → `reversers.Identity`

The journal entry (written by `internal/wizard/steps/identity.go`) carries:

```json
{
  "action":"identity_set",
  "target":"<workspace>/.git/config",
  "before":{"user.name":"<prev or empty>","user.email":"<prev or empty>"},
  "after": {"user.name":"<new>","user.email":"<new>"}
}
```

Reverser logic:

1. If `target` file does not exist → return `noop` (`workspace .git/config already absent`).
2. If `before.user.name == "" && before.user.email == ""` → call `identity.ClearWorkspaceIdentity(workspace)` (removes `[user]` block from the workspace `.git/config`).
3. Otherwise → call `identity.RestoreWorkspaceIdentity(workspace, before.user.name, before.user.email)`.

Failure modes: IO errors on the .git/config write → return `fail` with the underlying error.

### 7.2 `install_success` → `reversers.ToolInstall`

The journal entry (written by `internal/cli/repair.go`) carries:

```json
{
  "action":"install_success",
  "target":"<tool-id>",
  "result":"ok"
}
```

> **Spec amendment to alpha.3:** alpha.3's `install_success` entry currently carries no `method` or `package-id` information — only the tool ID. To enable per-package-manager uninstall dispatch, alpha.3's entry shape must be **extended** to include `after: {method: "<winget|brew|...>", package_id: "<id>"}`. This is a backwards-compatible additive change; the alpha.3 implementation will be updated in alpha.4's PR. Alpha.3 acceptance tests that asserted on the entry shape get an `after` assertion added; no existing assertion is invalidated.

Reverser logic:

1. Read `after.method`. If absent → return `fail` ("`install_success` entry missing `method` field — cannot dispatch uninstall; resolve manually").
2. If `--include-tools` is false → return `skip` (per §5.3 default).
3. Prompt per-tool confirmation. Quit → return `skip` ("user quit"). No → return `skip` ("user declined").
4. Dispatch `install.Uninstall(method, target)` — runs the appropriate uninstaller (`winget uninstall`, `brew uninstall`, `apt-get remove -y`, `dnf remove -y`, `snap remove`, `npm uninstall -g`).
5. Non-zero exit → return `fail` with the exit code and last lines of stderr.

### 7.3 Reverser interface

```go
// Reverser reverses one journal entry's effect.
type Reverser interface {
    // Reverse runs the per-action reversal. Returns Outcome describing
    // what happened. Implementations must be idempotent: re-running a
    // reverser whose target state is already absent returns Outcome{
    // Status: "noop"} rather than erroring.
    Reverse(entry journal.Entry, opts Options) Outcome
}

type Outcome struct {
    Status  string // "ok" | "noop" | "skip" | "refused" | "fail"
    Details string
}

type Options struct {
    IncludeTools bool
    Force        bool
    Prompt       prompt.Prompter
}
```

Dispatch table in `internal/undo/undo.go`:

```go
var reversers = map[string]Reverser{
    "identity_set":    reversers.Identity{},
    "install_success": reversers.ToolInstall{},
}
```

Unknown action → `Outcome{Status: "noop", Details: "unknown action type: <x>"}`. Forward-compatible — future alphas register their reversers in this map.

## 8. Acceptance tests (the alpha.4 RED gate)

Following the alpha.1 / alpha.2 / alpha.3 pattern: hermetic acceptance tests at `tests/acceptance/`. These build the real binary and exercise the `undo` subcommand. The tool-install reverser is exercised via the same `type: mock` installer dispatch alpha.3 introduced (extended with an `uninstall` outcome).

```go
TestUndo_NoJournal_ExitsZero                              // no journal.ndjson → "nothing to reverse" + exit 0
TestUndo_EmptyJournal_ExitsZero                            // journal exists, no reversible entries → exit 0
TestUndo_IdentitySet_RestoresPreviousConfig                // identity_set with non-empty Before → restores user.name/email
TestUndo_IdentitySet_EmptyBefore_RemovesUserBlock          // identity_set with empty Before → removes [user] block
TestUndo_IdentitySet_AlreadyAbsent_NoOp                    // .git/config gone before undo runs → noop, exit 0
TestUndo_ToolInstall_Default_Skips                         // install_success entry, no --include-tools → skip, exit 0
TestUndo_ToolInstall_IncludeTools_Uninstalls               // --include-tools → mock uninstall, entry_undone written
TestUndo_ToolInstall_MissingMethodField_Fails              // install_success entry without after.method → exit 7
TestUndo_InstallFailedEntry_NoOp                            // install_failed entry → noop (not in reverser table)
TestUndo_AlreadyUndone_SkipsReversedEntry                  // entry_undone marker present for X → X is skipped on second run
TestUndo_TargetIdentity_ScopesOnly                         // --target identity ignores install_success entries
TestUndo_TargetToolID_ScopesOnly                           // --target tool:dotnet-10 ignores other tools
TestUndo_TargetUnknown_ExitsOneWithMsg                     // --target xyz, no matches → exit 1
TestUndo_LegacyEntryNoID_SkippedWithInfo                   // pre-alpha.4 entry (no id) → info line, skipped
TestUndo_LockHeld_ExitsOne                                 // pre-existing session.lock → exit 1
TestUndo_ForceUnlock_ClearsExistingLock_ExitsZero          // --ForceUnlock + stale lock → succeeds
TestUndo_Unattended_RequiresForce                          // --unattended without --force → exit 1
TestUndo_Unattended_WithForce_Runs                         // --unattended --force --config-file ... → runs
TestUndo_AuditSnapshot_Written                             // journal.ndjson.undone-<ts> exists after run
TestUndo_AuditSnapshot_FailureWarnsNotFails                // simulate copy failure → warn, exit unchanged
```

Plus unit tests per package (`internal/undo`, `internal/undo/reversers`, `internal/journal` Read + ID-population paths, `internal/install.Uninstall`, `internal/identity.RestoreWorkspaceIdentity`).

Estimated count: ~19 acceptance + ~12 unit. Adjust during implementation.

## 9. Deferred from alpha.4 to subsequent alphas

Each reverser lands with its producing alpha:

| Action type | Producing alpha | Notes |
|---|---|---|
| `create_folder` / `rename_folder` / `remove_empty_folder` | alpha.5 (folder taxonomy) | Reversers added in alpha.5 PR alongside the producers. |
| `seed_readme` / `refresh_readme` | alpha.5 | Same. PS-era already has the hash-divergence + base64-content-restore discipline; port verbatim. |
| `clone_repo` | alpha.6 (repos + GH auth) | Plus the uncommitted-changes / unpushed-commits safety checks. |
| `gh_auth_login` | alpha.6 | `gh auth logout --hostname github.com`. |
| `create_workspace_file` / `create_file` | alpha.N (extras step) | Including workspace-docs (the PS work that was reverted in this session). |
| `install_ca_claude_plugin` | alpha.N (extras step) | Symlink removal. |
| `install_wsl` | alpha.N (extras step) | Always manual per PS; reverser emits guidance, returns `noop`. |

Other deferrals:
- `undo --dry-run` (beta.1)
- `undo --json` (beta.1)
- Multi-pass / retry-on-failure (post-v1.0 if at all)
- Audit-snapshot rotation / compaction (v1.0)

## 10. Acceptance criteria for alpha.4

1. ~19 acceptance tests from §8 exist (RED), then pass (GREEN).
2. `go test ./...` clean on all hosts.
3. `go test -tags acceptance ./tests/acceptance/...` reports the cumulative count PASS (alpha.1 + alpha.2 + alpha.3 + 19 alpha.4 = ~41 — exact number depends on alpha.3 final count). Existing tests for alpha.3's `install_success` entry shape updated to assert on the new `after.method` / `after.package_id` fields.
4. Manual smoke on a real machine: run `setup` end-to-end, run `repair --target jq` (or another tool the manifest knows), then `ca-bootstrap undo` → identity reversed; `ca-bootstrap undo --include-tools` → jq uninstalled. Verify `journal.ndjson` shows `entry_undone` lines and `journal.ndjson.undone-<ts>` snapshot exists.
5. AB# filed before any code lands. AB#40188.
6. README gains an `undo` section (mirror the `repair` section's pacing).
7. `collaboration-workflow.html` status pills evolve: alpha.4 → DONE; alpha.5 → IN PROGRESS or PLANNED.
8. CHANGELOG `Unreleased` entry under `Added` for `undo`.

## 11. References

- alpha.1 spec: [`2026-05-25-go-v2-0-alpha-1-spec.md`](2026-05-25-go-v2-0-alpha-1-spec.md)
- alpha.2 spec: [`2026-05-25-go-v2-0-alpha-2-spec.md`](2026-05-25-go-v2-0-alpha-2-spec.md)
- alpha.3 spec: [`2026-05-25-go-v2-0-alpha-3-spec.md`](2026-05-25-go-v2-0-alpha-3-spec.md)
- Pivot doc: [`2026-05-25-go-rewrite-pivot.md`](2026-05-25-go-rewrite-pivot.md)
- PS-era reference: [`legacy/commands/undo.ps1`](../../legacy/commands/undo.ps1) (487 lines; alpha.4 ports two of the eleven action-type branches — see §9 for the rest)

> Cross-doc links are correct relative paths; they resolve once the spec lands on `dev`.
