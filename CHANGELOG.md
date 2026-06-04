# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed (alpha.6 review follow-ups)

- **Unattended `setup` can now express an elevation choice for the inline install step.** A new optional `prereqs.elevation_action` key (`allow` | `deny` | `skip`, default `skip`) is threaded into the install path, so a missing required tool that needs elevation no longer falls through to the install package's interactive elevation prompt — whose answer keys live under `repair.*` and aren't present in setup answer files (which would error the strict unattended prompter). (AB#40272)
- **Removed a redundant post-install re-probe** in the prereqs step: it now reads the `InstallMissing` summary (which already verified each tool post-install) instead of re-scanning the whole manifest a second time. (AB#40272)

## [2.0.0-alpha.6] - 2026-06-04

### Changed (Go rewrite — v2.0.0-alpha.6: repair/setup actually install)

- **`repair` now fixes everything by default.** Running `ca-bootstrap repair` with no `--target` scans the manifest and installs every missing/below-min **required** tool after a single batch confirmation (`Install these N tools? [Y/n]`); `repair --all` also installs missing **optional** tools. `repair --target <id>` still installs one tool by id. Previously `--target` was mandatory, so you had to know the tool id and repair one at a time. (AB#40272)
- **`setup` installs missing tools inline.** The prerequisites step now offers to install missing required tools right there (prompt key `prereqs.install_missing`), using the same install path as `repair`, instead of only detecting drift and telling you to run `repair` later (which made it behave like `doctor`). Tools that can't be installed fall back to the existing continue-with-drift gate. (AB#40272)
- New **`internal/provision`** package — the shared "install what's missing" orchestrator (`Missing` + `InstallMissing`) used by both `repair` and the setup prereqs step, so they behave identically. Each install is journaled (`install_attempt` → `install_success`/`install_failed`) so `undo` can reverse it. No new external dependencies. (AB#40272)

## [2.0.0-alpha.5] - 2026-06-04

### Changed (Go rewrite — required prerequisites)

- **`psql` (PostgreSQL client) is now a required tool** (`optional: false`), joining the required set below. Needed by cm-currency-service staging scripts; `doctor`/`setup` now flag a missing `psql` as drift. `TestLoadDefault_RequiredToolSet` extended to cover it. (AB#40260)
- **`az`, `jq`, and `copilot-cli` are now required tools** (`optional: false`) in the embedded manifest, joining the already-required `git`, `gh`, `make`, and `pwsh`. The org's mandatory CLIs must all be present; `doctor`/`setup` now flag any missing one as drift rather than silently passing. A new `TestLoadDefault_RequiredToolSet` guards the az/gh/jq/git/make/copilot-cli set against accidental re-flipping. (AB#40233)
- **Detection probe timeout raised from 10s to 30s.** A cold-start `az --version` on Windows (a Python app) could exceed the prior 10s bound and be falsely reported missing even though it was present. 30s is generous for a slow first invocation while still bounding genuine hangs. (AB#40233)

### Added (Go rewrite — parity: optional extras)

- **`extras` setup step** (legacy step 80) — the final wizard step, five independently-confirmable offers: (1) a VS Code multi-root `ChannelAssist.code-workspace` file generated from the discovered clones; (2) workspace `.vscode/` defaults copied from embedded templates (existing files preserved); (3) a `ca-claude-plugin` activation symlink under `~/.claude/plugins/` (junction on Windows, symlink elsewhere); (4) `ca-copilot-plugin` usage notes; (5) a Windows-only WSL2 + Ubuntu install offer. Offers 3–4 appear only when the repo is cloned; offer 5 only on Windows. New `internal/extras` package with `CA_BOOTSTRAP_SYMLINK_MOCK` / `CA_BOOTSTRAP_WSL_MOCK` seams. Journals `create_file` (workspace + `.vscode` files, reversed by a new `CreateFile` reverser) and `install_ca_claude_plugin` (reversed by removing only the link). WSL/copilot actions are informational and not auto-reversed. **Note:** the Windows-only legs (junction creation, WSL probe) are covered by mock seams in tests and validated on real hardware at the Windows smoke step before release. (AB#40229)

### Added (Go rewrite — parity: repo cloning)

- **`repos` setup step** (legacy step 60) — the core bootstrap function. After folders, `setup` reads `internal/manifest/repos.yaml` and clones each group's repos into the workspace: a per-group prompt (`repos.group.<name>`, default skip when every repo is opt-in), a per-opt-in-repo prompt (`repos.repo.<slug>`, with `large`/`warn` notices), already-cloned skip + fetch, and a collision guard that flags a path that exists but isn't a valid clone of the expected repo rather than overwriting it. `requires_membership` repos are skipped with a note. New `internal/repos` package wraps `gh repo clone` with a clone timeout and a `CA_BOOTSTRAP_CLONE_MOCK` test seam. Successful clones journal `clone_repo` (reversed by `undo`, opt-in via `--include-folders`); a failed clone is non-fatal and cleaned up (the slot is restored to its pre-run absent state; nothing is journaled). Parallel cloning (`clone_concurrency`) and the legacy 3-way "Some" group choice are deferred. (AB#40227)

### Added (Go rewrite — parity: GitHub authentication)

- **`gh-auth` setup step** (legacy step 30). After prerequisites, `setup` checks `gh auth status`; an authenticated user passes as ✓, an unauthenticated one is offered the `gh auth login --git-protocol https --web` flow (answer key `gh-auth.login`). Declining or a missing `gh` soft-skips so identity/folders still run (cloning will be unavailable until authenticated). New `internal/ghauth` package wraps gh with timeouts and a `CA_BOOTSTRAP_GH_MOCK` test seam; `gh_auth_login` is journaled and reversed by `undo` (logout, opt-in via `--include-tools`). (AB#40226)

### Fixed (Windows robustness — found by live smoke test)

- **Console UTF-8 on Windows.** The wizard's glyphs (`✓ ⚠ → —`) rendered as mojibake (`Γ£ô`) in conhost / Windows PowerShell. `ca-bootstrap` now sets the console output code page to UTF-8 (65001) at startup on Windows (stdlib `syscall`, no new dependency; no-op elsewhere). (AB#40225)
- **`doctor` can no longer hang on a fresh Windows machine.** The winget presence probe now passes `--accept-source-agreements --disable-interactivity` (a first-run winget call otherwise blocks on an interactive prompt), and every detection probe — winget and `--version` alike — is bounded by a 10s timeout. (AB#40225)
- **`doctor` shows live progress.** A per-tool spinner is drawn while each probe runs (interactive terminals only; piped/unattended output stays plain), so a slow probe reads as working rather than frozen. (AB#40225)

### Added (Go rewrite — v2.0.0-alpha.5)

- **Workspace folder taxonomy** in the `setup` wizard. New step (`Folder structure`) runs after identity: reads `internal/manifest/folders.yaml`, creates each required folder under the workspace, migrates a `renamed_from:` predecessor (scalar OR list, most-recent → oldest) into the new path so prior-naming carryover folders move with their contents, and seeds a per-folder `README.md` from embedded templates. Optional folders are not auto-created but DO get migrated when a predecessor is on disk. Spec: [`docs/specs/2026-05-28-go-v2-0-alpha-5-spec.md`](docs/specs/2026-05-28-go-v2-0-alpha-5-spec.md). 14/14 acceptance tests GREEN. (AB#40189)
- **Four new undo reversers** registered in the alpha.4 dispatch map: `create_folder`, `rename_folder`, `seed_readme`, `remove_empty_folder`. CreateFolder refuses non-empty folders unless `--include-folders` is set (matches PS-era). SeedReadme uses an SHA-256 hash discipline: removes only when the on-disk content matches the embedded template — preserves user edits otherwise.
- **`internal/folders`** package with embedded README templates at `internal/folders/templates/folder-readmes/`. Copied from `legacy/templates/folder-readmes/`; the two trees diverge from this point.
- **`internal/manifest.FoldersManifest` + `LoadFoldersDefault()`** — parses `manifest/folders.yaml` from the embed (or `$CA_BOOTSTRAP_FOLDERS` override). `renamed_from` polymorphism (scalar vs list) handled via yaml.v3's `UnmarshalYAML` hook.
- **`--include-folders`** flag on `undo` (CLI). Split from the existing `--force` to disentangle the unattended-mode gate from the destructive-folder override (PS-era convention).

### Changed (Go rewrite — v2.0.0-alpha.5)

- **`undo.Options.IncludeFolders`** field; CreateFolder reverser reads this instead of the overloaded `Force`.
- `tests/acceptance/testdata/unattended-happy.yaml` + `unattended-drift-acknowledge.yaml` gain `folders.continue: true` so existing setup tests survive the new folders step.

### Added (Go rewrite — v2.0.0-alpha.4)

- **`ca-bootstrap undo`** — reverses changes recorded in the action journal. Closes phase D of the pivot roadmap (alpha.3 shipped `repair --target`; alpha.4 ships `undo`). Scoped to action types alpha.1–3 actually emit: `identity_set` (restores or removes the workspace `.git/config` `[user]` block) and `install_success` (uninstalls via the recorded package manager — opt-in via `--include-tools`, with per-tool consent). Honors `--target identity | tools | tool:<id>`, `--ForceUnlock`, `--force`, and `--unattended --config`. Spec: [`docs/specs/2026-05-28-go-v2-0-alpha-4-spec.md`](docs/specs/2026-05-28-go-v2-0-alpha-4-spec.md). 20/20 acceptance tests GREEN. (AB#40188)
- **Append-only `entry_undone` journal marker.** The PS-era `Set-CABEntryUndone` model (which mutates a YAML doc in place) does not port to the Go journal's append-only NDJSON. Successful reversals append a new `entry_undone` entry whose `target` carries the reversed entry's ID. Future undo runs skip any entry that already has a matching `entry_undone` marker.
- **`Entry.ID`** field on journal entries (random 20-hex from `crypto/rand`, populated at `Append` time). Entries from pre-alpha.4 sessions without an ID are skipped by `undo` with an info-level message — production users have no such entries since no release shipped before alpha.1.
- **`journal.Read(path)`** — parse the NDJSON journal back into a slice of `Entry`. The undo orchestrator's only journal reader.
- **`install.Uninstall(method, packageID)`** — alpha.4 counterpart of `Install`. Dispatches to `winget uninstall` / `brew uninstall` / `apt-get remove` / `dnf remove` / `snap remove` / `npm uninstall -g`, plus the mock outcome for acceptance tests.
- **`identity.RestoreWorkspaceIdentity` + `ClearWorkspaceIdentity`** — write or remove the workspace `.git/config` `[user]` block; the empty-section tidy-up keeps the file matching "as-if identity_set never ran".

### Changed (Go rewrite — v2.0.0-alpha.4)

- **`install_success` journal entry** now carries `after.method` (the package manager that succeeded) and `after.package_id`. Backwards-compatible additive change. Required so `undo`'s tool reverser can dispatch the matching uninstall.

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

[Unreleased]: https://github.com/ChannelAssist/ca-bootstrap/compare/v2.0.0-alpha.6...HEAD
[2.0.0-alpha.6]: https://github.com/ChannelAssist/ca-bootstrap/compare/v2.0.0-alpha.5...v2.0.0-alpha.6
[2.0.0-alpha.5]: https://github.com/ChannelAssist/ca-bootstrap/compare/v1.9.0...v2.0.0-alpha.5
[1.9.0]: https://github.com/ChannelAssist/ca-bootstrap/compare/v1.8.0...v1.9.0
