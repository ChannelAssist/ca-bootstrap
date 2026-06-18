# ca-bootstrap — Windows smoke test

Validates the paths never run on real Windows across the **full** wizard:
`doctor` detection, `setup` (prereqs → gh-auth → identity → folders → repos →
extras), `repair`'s winget dispatch, and `undo`'s reverser walk. Notably it
exercises the **real Windows junction** (`mklink /J`) created by the extras
plugin-link offer. Tracks AB#40188/40189/40225/40226/40227/40229/40233.

**Build under test:** whatever `ca-bootstrap.exe` you point `-Exe` at (or drop
next to this script) — the script prints that build's version line in the
summary, so this harness is not pinned to a release. The required-tool set is
**az, gh, jq, git, make, copilot-cli, pwsh, psql** — so on a box missing any of
these, `doctor` exits **2** (drift). That is still a PASS in this smoke (only
exit 1 is a real failure); `repair --target <tool>` installs the missing one.
The detection probe timeout is 30s so a slow cold-start `az --version` isn't
falsely reported missing.

> **Automated coverage:** the `windows-latest` leg of `.github/workflows/ci.yml`
> now runs the Go unit + acceptance suites on every push, including the
> windows-tagged code paths. This PowerShell harness remains the **end-to-end**
> check (real junction, real winget, real UAC) for a release candidate on a
> human-operated Windows box.

What's mocked vs real in the run: gh-auth is mocked (the real `gh auth login`
is interactive-only), the repo clone is mocked (offline/fast), and WSL is
mocked-present (so it isn't installed live). Everything else — folder taxonomy,
git identity, `.vscode/` defaults, the `.code-workspace` file, and the
`ca-claude-plugin` **junction** — is real. `-FullInstallTest` adds a real
`winget install jq` + uninstall.

## What you need
- The release `ca-bootstrap_<tag>_windows_<arch>.exe`, renamed to
  `ca-bootstrap.exe` and placed next to `smoke-windows.ps1` (or pass its path
  via `-Exe`).
- Git installed (it's a required tool; the no-op repair step expects it present).

## Run it (safe by default)
From PowerShell, in the folder with both files:

```powershell
# If scripts are blocked, allow for this process only:
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

.\smoke-windows.ps1
```

Or, without changing the policy, bypass for just this one run:

```powershell
powershell -ExecutionPolicy Bypass -File .\smoke-windows.ps1
```

This is **non-destructive**: everything runs in a throwaway sandbox under `%TEMP%`,
the action journal is redirected there (your real `~/.ca-bootstrap` is untouched),
and `setup` writes folders + identity into the sandbox, not your real workspace.
The `repair` step only exercises an already-installed tool (git) — it installs nothing.

## Optional: test the real install/uninstall leg
This actually runs `winget install jqlang.jq` and then uninstalls it via `undo`.
Only run if installing/removing **jq** on this machine is fine:

```powershell
.\smoke-windows.ps1 -FullInstallTest
```

## SmartScreen
Release binaries are Authenticode-signed when the `WINDOWS_CERT_*` secrets are
configured (see `.github/workflows/release.yml` and
`docs/guides/windows-code-signing.md`); a signed exe runs without a publisher
warning. If you're testing an **unsigned** build — a local `go build`, or a
release cut before the signing secrets were set — Windows may warn "unknown
publisher" → **More info → Run anyway**. That's expected for unsigned builds,
not a smoke failure.

## What to send back
Copy the whole **SMOKE SUMMARY** block the script prints at the end (it lists
PASS/FAIL per phase + the version line). If anything says FAIL, also re-run with
`-KeepSandbox` and send the `transcript.txt` path it reports.

Expected: all phases PASS. `doctor` exit 2 is fine (just means a required tool is
missing/old on this box) — only exit 1 there is a real problem.
