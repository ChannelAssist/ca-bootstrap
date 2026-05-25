# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Project status

- **2026-05-25 — Go-rewrite pivot.** The PowerShell implementation of `ca-bootstrap` is being archived in place and replaced by a Go CLI distributed as pre-built static binaries per platform via GitHub Releases. Trigger: three independent first-use bugs surfaced in a single session (broken Windows install one-liner, mojibake'd `make` output, frozen `./make.ps1 setup`), all symptoms of a recurring stdio/console/encoding bug class that six prior commits have addressed without eliminating. Rationale and roadmap: [`docs/specs/2026-05-25-go-rewrite-pivot.md`](docs/specs/2026-05-25-go-rewrite-pivot.md). No new features will land on the PowerShell codebase; the last PS-era commit is tagged for archival reference. Process going forward: spec → tests → code, strict order. Authored by Peter Giannopoulos with Claude Code (AI-assisted).

## [1.9.0] - 2026-05-24

### Added

- **`ChannelAssist/keystone-runtime` in the docs group** — `manifest/repos.yaml` now clones the Keystone runtime repo to `ca-docs/keystone-runtime` on `dev`, co-located with `ca-docs/keystone` (the Astro Starlight content). No special flags (public, default-included). Tracks AB#39913; sibling of the keystone-runtime scaffolding work (AB#39837, AB#39839, AB#39840, AB#39841) under Epic #38056 (AI Platform & Workflow Integration — 2026). Corrects an earlier draft of this entry that used the wrong slug (`ca-keystone-runtime`); the actual repo has no `ca-` prefix, matching the `docs` group's existing convention (`Keystone`, `.github`).
- Required workspace folder `ca-work-dirs/` for Claude Code worktrees, Claude Cowork sessions, and scratch clones (AB#40007).
- `README.md` template per top-level workspace folder, copied idempotently by step 50 (AB#40007).
- `doctor` check `folder-rename:<old>` driven by new `renamed_from:` field in `folders.yaml` (AB#40007).
- `repair --target folder-renames` migrates workspace folders to their renamed paths per the new safety contract (AB#40007).
- `repair --target folder-readmes` re-syncs README templates with explicit confirmation before overwriting drift (AB#40007).
- `scripts/wiki-sync.sh full` / `scripts/wiki-sync.ps1 full`: single-shot clone-if-missing + sync + push (AB#40007).
- `repair --target folder-tree-refresh` regenerates the `## Tree` fenced block in each workspace folder's `README.md` from `manifest/repos.yaml`. Idempotent; explicit-only (no `--all` coverage). Preserves the file's native line endings (LF vs CRLF) and any pre-existing UTF-8 BOM. Skips folders whose README is missing or whose Tree section has no fenced block (warning, no error). Fence search is bounded to the Tree section so an unfenced Tree section + later fenced section (e.g. `## Examples`) cannot cross-contaminate. (#81, AB#40022)
- `renamed_from:` may now be a **scalar OR a list** of historical folder names, walked most-recent → oldest. `Get-CABFolderRenamedFrom` exposes the normalised chain to doctor, repair, and step 50, so a multi-step rename history (e.g. `[ca-experiments, experiments]`) is detected end-to-end. doctor emits one `folder-rename:<old>` check per predecessor still on disk; `repair --target folder-renames` iterates each predecessor in turn. (#82, AB#40023)
- `repair --target folder-readmes` now captures pre-overwrite README content into the journal under `previous_content` (base64-encoded, capped at 64KB source bytes). `undo` of the resulting `refresh_readme` entry restores the captured bytes byte-for-byte, with a divergence guard that refuses to overwrite when the current README has been edited since repair (hash mismatch vs the recorded template, hash compute failure, or template missing — all return `skip`/`fail`, mirroring the existing `seed_readme` discipline). 0-byte READMEs round-trip correctly via key-presence detection (not truthiness). (#83, AB#40024)
- Typed `CABNoActiveSessionException` (`lib/journal.ps1`) — symmetric with the existing `CABSessionLockedException`, so orchestrator-level `catch` blocks can distinguish "concurrent run" from "missing `Start-CABSession` upstream" without parsing message strings. (#80, AB#40021)
- `Start-CABSession` and `Stop-CABSession` gain a `-Quiet` switch. The orchestrator pipes `-Quiet:$silent` at both ends so `--json` / `--quiet` mutating commands (`setup`, `repair`, `undo`, `manifest-edit`) stay clean on stdout end-to-end. Lock acquisition, journal I/O, transcript rotation, and session-metadata recording all still happen — only the banner blocks are suppressed. (#80, AB#40021)

### Changed

- Workspace folder `experiments/` renamed to `ca-experiments/` (ADR-0017 `ca-*` convention) (AB#40007).
- `make help` (and `make.ps1 help`) restyled with Keystone-style sectioned banner: Workspace / Tools / Manifest / Quality / Smoke & Cleanup / Wiki / Releases (AB#40007).
- `wiki-update` is now the single public Make target for wiki sync. `wiki-clone`, `wiki-sync`, `wiki-push` removed (AB#40007).
- **Safety contract**: `ca-bootstrap` will never delete a non-empty folder, or any folder containing sub-folders, without explicit user confirmation. Sub-folders may belong to other tools (Claude Cowork, IDE scratch); the rule is enforced across `steps/50-folders.ps1`, `commands/repair.ps1`, and `commands/undo.ps1` (AB#40007).
- **`Add-CABJournalEntry` now throws `CABNoActiveSessionException` when no session is active** — previously a silent `$null` return that created invisible audit-trail gaps in production. `Get-CABCurrentSession` is now O(1) via a cached `$Script:CABActiveSession` reference (immune to id-collision races on second-granularity timestamps); `Read-CABJournal` calls `Sync-CABActiveSession` at every state-replacement path so `commands/doctor.ps1` / `commands/undo.ps1` cross-checks don't orphan the cache. (#80, AB#40021)
- **doctor `folders` check and step 50 preview** distinguish **collision** (path exists but is not a directory) from **missing** before walking the renamed_from chain — mirroring `Invoke-CABStep50`'s execution branches. Collisions report `status: fail` with `collisions: [...]` and deliberately no `fix` recipe; a regular file at a required-folder path can no longer be misadvertised as a "↻ rename predecessor" the step would refuse to execute. (#82, AB#40023)
- `lib/folder-readmes.ps1` (extracted from step 50 in #74) is now also dot-sourced by the orchestrator's lib loader. Tests driving step 50 / repair `folder-renames` directly must dot-source `lib/folders.ps1` in their BeforeAll (the orchestrator handles it in production). (#81, #82)

### Removed

- **Archived `ChannelAssist/nlp-learning-paths` from `ca-training` group** — `manifest/repos.yaml` no longer references this repo. Per policy, archived-on-GitHub repos don't belong in the clone manifest. Auto-detected and queued for removal by `manifest-edit` during release validation. (AB#39913)
- **psql (PostgreSQL client) in the optional tools manifest** — `manifest/tools.yaml` now lists `psql` under `optional:` with `needed_by_groups: [cm-product]`. Required by `cm-currency-service`'s `make staging-seed-qa` (and any future staging op that pipes SQL into the staging Postgres). macOS installs via Homebrew `libpq` with a `post_install` `brew link --force --overwrite libpq` (libpq is keg-only); Windows uses winget `PostgreSQL.PostgreSQL.16`; Linux uses `postgresql-client` (debian) / `postgresql` (rhel). Tracks AB#39851; predecessor in-repo fix at [cm-currency-service#220](https://github.com/ChannelAssist/cm-currency-service/pull/220) (AB#39850).

### Security

- **Pre-overwrite README content is scanned for credential patterns BEFORE base64-encoding** (`repair --target folder-readmes`). The scan tries UTF-8, UTF-16LE, AND UTF-16BE decodes and matches the same `Test-CABContainsSensitive` pattern set the journal's existing string-value guard uses (GH/AWS/Slack/JWT/PEM prefixes). On a match the snapshot is held back (`previous_content_captured: false`) — the overwrite still proceeds, only the journaling is suppressed, so secrets can't round-trip into `~/.ca-bootstrap/journal.yaml` via base64. (#83, AB#40024)
- **`undo refresh_readme` refuses to overwrite a diverged README**. Before writing the captured bytes, it compares `SHA256(current README)` to `SHA256(recorded template)`. Mismatch → `skip` with a recovery recipe; hash-compute failure → `fail` (refuse blind write); template missing on disk → `skip` (mirrors the existing `seed_readme` discipline). User edits made after `repair --target folder-readmes` are now preserved across `undo`. (#83, AB#40024)

[Unreleased]: https://github.com/ChannelAssist/ca-bootstrap/compare/v1.9.0...HEAD
[1.9.0]: https://github.com/ChannelAssist/ca-bootstrap/compare/v1.8.0...v1.9.0
