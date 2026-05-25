# ca-bootstrap v2.0.0-alpha.3 — implementation spec

- **Date:** 2026-05-25
- **Author:** Peter Giannopoulos (4 brainstorm decisions) + Claude Code (AI-assisted drafting)
- **Status:** Draft → pending Peter review of §2.B autonomous calls
- **Work item:** TBD — file new PBI before any code lands
- **Builds on:** [alpha.1 spec](2026-05-25-go-v2-0-alpha-1-spec.md), [alpha.2 spec](2026-05-25-go-v2-0-alpha-2-spec.md), [pivot doc](2026-05-25-go-rewrite-pivot.md)

## 1. TL;DR

`v2.0.0-alpha.3` adds `ca-bootstrap repair --target <tool-id>` — install one missing tool per the manifest's `install:` block. Cross-platform (winget on Windows, brew on macOS, apt/dnf on Linux). Hybrid elevation: prompt the user when sudo/UAC is needed, with a **skip** option that defers to a "manual install required" summary at the end of the session. Introduces real OS-level session locking (`flock` on Unix, `LockFileEx` on Windows) at `~/.ca-bootstrap/session.lock`. Every install attempt — succeeded, failed, or skipped — is recorded in the action journal so alpha.4's `undo` can reverse them.

## 2. Decisions

### 2.A — Carried from prior alphas (no change)

Repo layout, binary name (`ca-bootstrap`), versioning (`v2.0.0-alpha.N`), manifest format (YAML in `internal/manifest/`), telemetry (none ever), code signing (defer to v2.0.0 final), TUI (none), dependencies (cobra, yaml.v3, stdlib only — adding any requires explicit rationale).

### 2.B — Locked via brainstorming (2026-05-25, all confirmed by Peter)

| # | Decision | Choice | Notes |
|---|---|---|---|
| 1 | **alpha.3 scope** | `repair --target <tool-id>` only | --all, --dry-run, --json defer to alpha.3.x or alpha.5. Smallest discipline gate; parallels alpha.1 (doctor-only). |
| 2 | **Elevation handling** | **Hybrid prompt with skip-to-manual** | When a tool needs sudo/UAC, prompt: `[Y/n/skip]`. Y → run elevated. n → quit. skip → record as `manual-install-required`, continue. End of session: print manual instructions for every skipped tool. |
| 3 | **Partial failure (multi-step installs)** | Continue, then report summary | Even for `--target` scope, a single tool's install may have multiple steps (e.g., `curl get.docker.com | bash` + `sudo usermod -aG docker $USER`). Continue past per-step failures and summarize. Exit code reflects worst outcome. |
| 4 | **Session locking** | Real OS lock — `flock` on Unix, `LockFileEx` on Windows | At `~/.ca-bootstrap/session.lock`. `--ForceUnlock` flag for stale-lock recovery (mirrors PS-era). |

### 2.C — Autonomous calls (lower stakes — flagged for redirect if needed)

| # | Decision | Choice | Reasoning |
|---|---|---|---|
| 5 | **Detecting "needs elevation"** | Per-installer heuristic: `apt`, `dnf`, `winget --scope machine`, anything starting with `sudo` → elevation. `brew`, `npm -g` (when prefix is user-owned), explicit `sudo: false` in manifest → no elevation. | Conservative defaults; the manifest can add an explicit `requires_elevation: bool` field if needed later. |
| 6 | **Tool dependencies (`requires:` field)** | Ignored in alpha.3 | The manifest already has `requires: [node-20]` etc. alpha.3 doesn't resolve them — it installs only the `--target`. If a dep is missing, the install command will fail naturally. alpha.4+ may add dependency resolution. |
| 7 | **Rollback on install failure** | No rollback | Leave the partial state; user can retry `repair` or run `doctor` to see what happened. alpha.4's `undo` is the proper rollback mechanism. |
| 8 | **Re-doctor after repair** | No automatic re-run | `repair` reports what it did; user runs `doctor` explicitly to verify. Keeps each verb single-responsibility. |
| 9 | **Progress indication** | Stream installer output to stdout live | No spinner, no buffering — let the user see `apt`'s progress dots, `winget`'s download bar, etc. live. Matches expectations from running these tools directly. |
| 10 | **Install timeouts** | 10 minutes per install command | Docker Desktop on macOS can take 5+ minutes. 10 minutes is generous; SIGKILL on timeout. Configurable via `$CA_BOOTSTRAP_INSTALL_TIMEOUT_SECONDS` env var. |
| 11 | **Network failures** | Surface stderr verbatim; exit 1 (not 2) | Network failures are system errors, not drift. Distinct exit-code category. |
| 12 | **`repair` exit codes** | 0 = success, 1 = system error (manifest, lock, network), 2 = install failure or `skip` chosen | Same convention as `doctor`. |

## 3. Non-goals (explicitly OUT of alpha.3)

- `repair --all` (alpha.3.x or alpha.5)
- `repair --dry-run` (alpha.3.x or alpha.5)
- `repair --json` (beta.1)
- Tool dependency resolution (alpha.4+)
- Automatic rollback on failure (alpha.4 = `undo`)
- Folder taxonomy (alpha.5+)
- Repo cloning (alpha.6+)
- GH authentication via repair (alpha.6 — `gh auth login` becomes a repair target)
- TUI. Ever.

## 4. Architecture additions on top of alpha.2

### 4.1 New Go packages

```
internal/
├── install/                          # NEW: install dispatch per platform
│   ├── install.go                    # Installer interface + Result type
│   ├── install_unix.go               # //go:build darwin || linux: brew, apt, dnf, npm, script, etc.
│   ├── install_windows.go            # //go:build windows: winget, npm, etc.
│   ├── elevation.go                  # detects whether a command needs elevation
│   └── *_test.go
├── lock/                             # NEW: cross-platform session lock
│   ├── lock.go                       # Lock/Unlock interface
│   ├── lock_unix.go                  # //go:build darwin || linux: syscall.Flock
│   ├── lock_windows.go               # //go:build windows: LockFileEx via syscall
│   └── lock_test.go
└── cli/
    └── repair.go                     # NEW: cobra `repair` subcommand
```

### 4.2 Updates to existing packages

- `internal/manifest/manifest.go`: extend `Tool` to parse the `install:` block (currently `yaml.Node` ignored). Add `RequiresElevation bool` opt-in field. Backwards-compatible — existing manifests keep working.
- `internal/journal/entry.go`: new actions `install_attempt`, `install_success`, `install_failed`, `install_skipped`, `manual_install_required`.
- `internal/cli/setup.go`: optional — invoke session lock at start (currently setup doesn't lock; alpha.3 lands the lock + applies it to both setup and repair).

### 4.3 No new external dependencies

cobra + yaml.v3 + stdlib still cover everything. `syscall` for the OS locks. `os/exec` for installer invocation.

## 5. Functional spec — `repair --target`

### 5.1 Behavior — interactive mode

```text
$ ca-bootstrap repair --target dotnet-10

Checking installed state of dotnet-10...
  ✗ dotnet not found (manifest min: 10.0.0)

Installing dotnet-10 via brew (macOS)...
  Command: brew install dotnet-sdk
  This is not an elevated operation.
  Continue? [Y/n]  Y

  ==> Downloading https://...
  ==> Pouring dotnet-sdk--10.0.107.arm64_sequoia.bottle.tar.gz
  ==> Caveats
  ...
  ✓ Installed.

Verifying...
  ✓ dotnet now at 10.0.107 (manifest min: 10.0.0)

repair complete.
```

### 5.2 Behavior — elevation prompt path (Linux example)

```text
$ ca-bootstrap repair --target jq

Installing jq via apt (debian)...
  Command: apt-get install -y jq
  **This requires elevated privileges (sudo).**
  Continue? [Y/n/skip]  Y

  Running: sudo apt-get install -y jq
  [sudo] password for peter:
  ...
  ✓ Installed.

Verifying...
  ✓ jq now at 1.7.1
```

### 5.3 Behavior — skip path

```text
$ ca-bootstrap repair --target jq

Installing jq via apt (debian)...
  Command: apt-get install -y jq
  **This requires elevated privileges (sudo).**
  Continue? [Y/n/skip]  skip

  ⊘ Marked as manual-install-required.

repair complete (with manual steps needed):
  - jq: run `sudo apt-get install -y jq` manually
```

Exit code: 2 (drift remains).

### 5.4 Exit codes

| Exit | Meaning |
|---|---|
| `0` | Tool installed and verified; no drift remains for `--target` |
| `1` | System error (manifest missing/parse, lock acquisition failed, network failure, etc.) |
| `2` | Install failed OR user chose `skip` OR post-install verification shows drift still present |
| `130` | User chose `n` at the elevation prompt (treated as quit) |

### 5.5 The `--ForceUnlock` flag

```text
$ ca-bootstrap repair --target dotnet-10 --ForceUnlock
```

Clears any existing `~/.ca-bootstrap/session.lock` before acquiring the new one. Capitalization mirrors the PS-era `-ForceUnlock` flag exactly so onboarding hires' muscle memory carries over.

## 6. Functional spec — session lock

### 6.1 Cross-platform interface

```go
// internal/lock/lock.go
type Lock interface {
    Acquire() error           // blocks until acquired or returns error
    AcquireWithForce() error  // breaks any existing lock then acquires
    Release() error
}

func New(path string) Lock   // returns platform-appropriate impl
```

### 6.2 Unix implementation (`detect_unix.go`)

`syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB)`. Lock released on file close or process exit (kernel-managed). Stale locks from crashes are auto-cleared by the kernel.

### 6.3 Windows implementation

`LockFileEx` via `syscall` package with `LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY`. Auto-released on handle close.

### 6.4 ForceUnlock semantics

When `--ForceUnlock` is passed: `os.Remove(lockPath)` BEFORE attempting to acquire. Documented as "use this when a previous run crashed and the lock won't release."

### 6.5 Setup also takes the lock (in alpha.3)

The `setup` subcommand in alpha.2 doesn't lock. alpha.3 retroactively wraps `setup`'s entry in the same lock-acquisition logic, since two simultaneous `setup` runs could interleave journal entries and corrupt the audit trail.

## 7. Functional spec — action journal extensions

### 7.1 New entry types

| Action | Recorded when | `before` / `after` |
|---|---|---|
| `install_attempt` | Just before running the installer command | `before: {state: missing}`, no `after` (yet) |
| `install_success` | Installer returned exit 0 AND post-install verification passes | `after: {version: <detected>}` |
| `install_failed` | Installer returned non-zero, OR post-install verification fails | `after: {exit_code, last_lines_of_stderr}` |
| `install_skipped` | User chose `skip` at elevation prompt | `after: {reason: skipped_elevation}` |
| `manual_install_required` | End-of-session summary entry per skipped tool | `after: {command: <the manual command>}` |

### 7.2 Why every attempt is journaled

So alpha.4's `undo` can:
- For `install_success`: run the corresponding uninstall command (`brew uninstall`, `apt-get remove`, etc.)
- For `install_failed`: do nothing — no state to reverse
- For `install_skipped`: do nothing — user took the manual path

## 8. Acceptance tests (the alpha.3 RED gate)

Following the alpha.1 / alpha.2 pattern: ~5-6 hermetic acceptance tests at `tests/acceptance/`. These tests **build the real binary** and exercise the `repair` subcommand. They use a **mock installer** because we cannot run real `brew install` / `apt install` in tests.

The mock installer is selected via env var `$CA_BOOTSTRAP_INSTALLER_OVERRIDE=mock` (parallels how `$CA_BOOTSTRAP_MANIFEST` works). The mock returns canned results based on the tool ID — e.g., `success-tool` → exit 0, `fail-tool` → exit 1, `needs-elevation-tool` → triggers the elevation prompt.

```go
TestRepair_TargetNotInManifest_ExitsOne                  // --target xyz when xyz isn't in manifest → exit 1 + stderr msg
TestRepair_AlreadyInstalled_ExitsZeroNoOp                 // tool present + at version → no install attempt, exit 0
TestRepair_HappyPath_InstallsAndVerifies                  // tool missing → mock install succeeds → exit 0
TestRepair_InstallFailure_ExitsTwo                        // mock install returns error → exit 2
TestRepair_ElevationPromptDeclined_ExitsOneThirty         // unattended config sets repair.allow_elevation: false → exit 130
TestRepair_ElevationSkipChosen_ExitsTwoWithManual         // unattended config sets repair.elevation_action: skip → exit 2 + manual-install summary in stdout
TestRepair_LockHeld_ExitsOne                              // pre-existing lock → exit 1 + clear message
TestRepair_ForceUnlock_ClearsExistingLock_ExitsZero       // --ForceUnlock + stale lock → succeeds
```

Plus integration tests per new package (install, lock, elevation detection).

## 9. Deferred from alpha.3 to subsequent specs

- alpha.4: `undo --target` + `--all`. Replays the action journal in reverse.
- alpha.3.1: `repair --all` (iterates everything `doctor` flags as drift).
- alpha.3.2: `repair --dry-run`.
- alpha.5: Folder taxonomy port.
- alpha.6: Repo cloning + GH auth.
- beta.1: `--json` flags, self-update.
- v2.0.0 final: signing, parity check vs `legacy/v1.9.0`.

## 10. Acceptance criteria for alpha.3

1. ~8 acceptance tests from §8 exist (RED), then pass (GREEN).
2. `go test ./...` clean on all hosts (when CI is re-enabled).
3. `go test -tags acceptance ./tests/acceptance/...` reports 22/22 PASS (7 alpha.1 + 7 alpha.2 + 8 alpha.3).
4. Manual smoke on a real machine: `ca-bootstrap repair --target jq` (or some genuinely-missing tool) actually installs it. Lock semantics validated by running `setup` and `repair` in two terminals simultaneously.
5. AB# filed before any code lands.
6. README gains a `repair` section.
7. Collaboration HTML status pills evolve.

## 11. References

- alpha.1 spec: [`2026-05-25-go-v2-0-alpha-1-spec.md`](2026-05-25-go-v2-0-alpha-1-spec.md)
- alpha.2 spec: [`2026-05-25-go-v2-0-alpha-2-spec.md`](2026-05-25-go-v2-0-alpha-2-spec.md)
- Pivot doc: [`2026-05-25-go-rewrite-pivot.md`](2026-05-25-go-rewrite-pivot.md)
- Tutorial: [`../tutorials/tdd-walkthrough.md`](../tutorials/tdd-walkthrough.md) (alpha.3 will add Part III chapters 20+)
