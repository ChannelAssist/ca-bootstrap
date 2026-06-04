# ca-bootstrap v2.0.0-alpha.7 — implementation spec

- **Date:** 2026-06-04
- **Author:** Peter Giannopoulos + Claude Code (AI-assisted drafting)
- **Status:** Accepted — implementing
- **Work item:** [AB#40270](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/40270) — alpha.7 (child of Epic AB#38056)
- **Builds on:** alpha.1–alpha.6 (esp. alpha.6's `internal/provision` install path)
- **Reference (QA-only PowerShell):** [`dist/smoke-windows.ps1`](../../dist/smoke-windows.ps1) — the real legs this ports into Go.

## 1. TL;DR

`doctor` today only does **passive detection** ("is tool X present at version Y"). alpha.7 adds a **capability self-test**: `doctor --deep` verifies the host can actually perform the operations bootstrap depends on — not just that tools exist. The safe probes are non-destructive/self-reversing and run by default under `--deep`; a real install→uninstall round-trip runs only under the explicit `doctor --deep --full` opt-in (mirrors the smoke harness's `-FullInstallTest`). New `internal/selftest` package; the probes become the cross-platform single source of truth so the PowerShell smoke can shrink to a thin wrapper over them.

## 2. Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | **Surface** | Flags on `doctor`: `--deep` (safe capability probes after the detection report) and `--full` (adds the real install round-trip; implies/requires `--deep`). Bare `doctor` is unchanged — fast, read-only detection. Matches Peter's framing ("doctor validates the ability to install/configure"). |
| 2 | **Safe-by-default** | `--deep` runs only non-destructive / self-reversing probes. The genuinely invasive real install/uninstall is gated behind `--full`. (Peter's choice: "safe probes default, install behind a flag".) |
| 3 | **Safe probe set** | (a) workspace-root writable; (b) symlink/junction create+remove in a temp dir; (c) platform package manager reachable; (d) `gh auth` live. Each self-reverses (temp files/links removed; version commands are read-only). |
| 4 | **`--full` round-trip** | Install→uninstall a **probe tool** resolved from the manifest (default `kubectl` — optional, not a required tool, modest size; override via `$CA_BOOTSTRAP_SELFTEST_PROBE`). **Absent-only**: if the probe tool is already present, skip (never remove a tool the user has). Reuses alpha.4's `install.Install`/`install.Uninstall`. |
| 5 | **Exit codes** | `doctor --deep`: 0 = detection clean AND all safe probes ok; 2 = drift OR any probe failed; 1 = system error. `--full` failures count the same as a failed probe (exit 2). A skipped probe (e.g. probe tool already present, or mocked-skip) is not a failure. |
| 6 | **Mock seams** | Reuse `CA_BOOTSTRAP_SYMLINK_MOCK` (link probe). New `CA_BOOTSTRAP_PKGMGR_MOCK` (package-manager probe: `ok`/`fail`). `--full` round-trip uses the existing install `type: mock` seam via a test manifest. `gh auth` reuses `CA_BOOTSTRAP_GH_MOCK`. No new dependencies. |

## 3. Non-goals (OUT of alpha.7)

- Replacing the PowerShell smoke wrapper (it keeps calling the exe; pointing it at `doctor --deep` is a follow-up).
- Auto-remediation of a failed capability (doctor stays diagnostic).
- `self-update` (beta.1).

## 4. Architecture

- New **`internal/selftest`** package: `Capabilities(Options) []Result` (the 4 safe probes) + `InstallRoundTrip(Options) Result` (the `--full` leg) + `Run(Options) []Result`. `Result{Name, Status: ok|fail|skip, Detail}`.
- `internal/cli/doctor.go`: add `--deep` / `--full` flags; after the detection report, when `--deep`, run `selftest.Run` and fold the worst outcome into the exit code.
- Link + package-manager probes use `runtime.GOOS` inline (no build tags), matching `extras.makeLink`.

## 5. Acceptance tests (the alpha.7 RED gate)

- `doctor --deep` with all safe probes mocked-ok → exit 0 (against an all-present manifest).
- `doctor --deep` with the package-manager probe mocked-fail → exit 2.
- `doctor --deep --full` with a mock probe tool that installs+uninstalls ok → exit 0; reports the round-trip.
- Unit: each safe probe in isolation (temp dirs + mock seams), and the skip path when the probe tool is already present.

## 6. Acceptance criteria

Per AB#40270: safe probes by default; real install behind `--full`; cross-platform Go with mock seams; both platforms build, vet clean, full suite green; no new deps; reviewed + approved.
