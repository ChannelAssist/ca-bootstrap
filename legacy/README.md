# legacy/ — frozen PowerShell implementation of ca-bootstrap

This directory contains the **v1.9.0** PowerShell implementation of ca-bootstrap, frozen in place as of 2026-05-25.

**Why is it here?** See the pivot decision record: [`docs/specs/2026-05-25-go-rewrite-pivot.md`](../docs/specs/2026-05-25-go-rewrite-pivot.md).

**What's the archival tag?** [`legacy/v1.9.0`](https://github.com/ChannelAssist/ca-bootstrap/releases/tag/legacy%2Fv1.9.0) at commit `008b2e2`. Use `git checkout legacy/v1.9.0` to inspect the last functional PowerShell state.

**Will it still run?** Yes, subject to the known limitations the rewrite is escaping (see § 2 of the pivot doc — `iwr | iex` was already broken, `make` had Windows console encoding issues, `make.ps1 setup` could freeze on certain consoles). To use it directly from this directory:

```powershell
pwsh ./ca-bootstrap.ps1 setup
```

No new features will land here. Critical user-blocker bugs *may* be fixed minimally during the lame-duck period.

**Where's the active development?** The Go rewrite lives at the repo root. See the top-level [`README.md`](../README.md) and [`docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md`](../docs/specs/2026-05-25-go-v2-0-alpha-1-spec.md).

## What's in this directory

| Path | Was at root | Purpose |
|---|---|---|
| `bootstrap.ps1`, `bootstrap.sh` | yes | Curl-pipe entry points (also broken — see pivot doc) |
| `ca-bootstrap.ps1` | yes | Multi-command orchestrator (setup/doctor/repair/undo) |
| `make.ps1`, `Makefile` | yes | Task runners (Windows-native and GNU) |
| `lib/` | yes | Shared PowerShell helpers (journal, prompts, ui, ...) |
| `commands/` | yes | Implementations of setup/doctor/repair/undo/manifest-* |
| `steps/` | yes | The 8 numbered setup-wizard steps |
| `scripts/` | yes | Release machinery + wiki sync |
| `templates/` | yes | Folder-README templates copied into workspace |
| `tests/` | yes | Pester test suite |
| `.github/workflows/` | yes | CI + release workflows (disabled — moved here in the same commit as the migration to honor the no-CI-during-rewrite directive) |
| `GEMINI.md` | yes | Stale agent-instruction file (described PS-era code) |
| `TEST_PLAN.md` | yes | Historical test-plan artifact (v1.1.0 era) |

## What stays at the repo root (NOT here)

`manifest/` (the Go binary reads it directly, schema unchanged), `docs/`, top-level `.github/` content other than `workflows/` (CODEOWNERS, dependabot.yml, pull_request_template.md, agents/), `README.md`, `CHANGELOG.md`, `CLAUDE.md`, `DESIGN.md`, `.gitignore`.
