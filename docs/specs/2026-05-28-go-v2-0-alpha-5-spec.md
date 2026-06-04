# ca-bootstrap v2.0.0-alpha.5 — implementation spec

- **Date:** 2026-05-28
- **Author:** Peter Giannopoulos + Claude Code (AI-assisted drafting)
- **Status:** Accepted — implemented and tested (14/14 acceptance + unit coverage)
- **Work item:** [AB#40189](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/40189) — alpha.5 spec + plan PBI (child of Epic AB#38056)
- **Builds on:** [alpha.1](2026-05-25-go-v2-0-alpha-1-spec.md), [alpha.2](2026-05-25-go-v2-0-alpha-2-spec.md), [alpha.3](2026-05-25-go-v2-0-alpha-3-spec.md), [alpha.4](2026-05-28-go-v2-0-alpha-4-spec.md), [pivot doc](2026-05-25-go-rewrite-pivot.md)
- **Reference (PS-era parity target):** [`legacy/steps/50-folders.ps1`](../../legacy/steps/50-folders.ps1) (226 lines), [`legacy/lib/folder-readmes.ps1`](../../legacy/lib/folder-readmes.ps1) (80 lines)

## 1. TL;DR

`v2.0.0-alpha.5` ports the workspace folder taxonomy from PS step 50 to Go. New wizard step that runs after identity: reads `manifest/folders.yaml`, creates each required folder under the workspace, migrates predecessors named in `renamed_from:` into the new path (preserves data), and seeds a per-folder `README.md` from embedded templates. Journals every mutation as `create_folder` / `rename_folder` / `seed_readme`. Adds four reversers to alpha.4's `undo` dispatch table — `create_folder`, `rename_folder`, `seed_readme`, plus the producer-less `remove_empty_folder` reverser (its producer ships in alpha.6 with repo cloning). Defers `refresh_readme` to a later alpha alongside `repair --target folder-readmes`.

## 2. Decisions

### 2.A — Carried from prior alphas (no change)

Repo layout, binary name, versioning, manifest format (YAML in `internal/manifest/`), telemetry (none), code signing (defer to v2.0.0 final), TUI (none), dependencies (cobra, yaml.v3, stdlib only), session-lock semantics, journal append-only NDJSON + `entry_undone` markers, the spec → tests → code discipline.

### 2.B — Locked via brainstorming (pending Peter confirmation — date TBD)

| # | Decision | Choice | Notes |
|---|---|---|---|
| 1 | **alpha.5 scope** | Setup-side: folder creation + renamed_from migration + seed_readme. Undo-side: 4 new reversers (create_folder, rename_folder, seed_readme, remove_empty_folder). | Defer `refresh_readme` + its reverser to the alpha that introduces `repair --target folder-readmes`. The hash-divergence + base64-content-restore discipline doesn't belong in alpha.5's setup-time path. |
| 2 | **`renamed_from:` precedence** | Most-recent → oldest, single OR list. First predecessor that exists on disk wins; falls through to fresh create when no predecessor exists. | Verbatim port of the PS-era contract — operators who skipped an earlier rename get caught up automatically. |
| 3 | **Idempotent seed_readme** | Skip if target file exists. Never overwrite. Missing template emits an `info`-level warning but doesn't fail the step. | Matches PS-era. Refresh-on-drift is `repair --target folder-readmes` territory, not setup. |
| 4 | **Folders step ordering** | New wizard step after `identity`, before any future repo-cloning step. Step list becomes: welcome → prereqs → identity → folders. | Folders depend on workspace path (set by identity), and repos (future alpha.6) depend on folders. |
| 5 | **Templates location + embed** | `internal/folders/templates/folder-readmes/<folder>/README.md`. Embedded at build time via `//go:embed`. | Copied from PS-era `legacy/templates/folder-readmes/`. The two trees diverge over the rewrite arc — Go uses its own copy. |

### 2.C — Autonomous calls (lower stakes — flagged for redirect if needed)

| # | Decision | Choice | Reasoning |
|---|---|---|---|
| 6 | **Collision handling (path exists but is not a directory)** | Exit 1 with a clear message ("Path '<x>' exists but is not a directory; resolve manually"). No automatic resolution. | Same as PS-era. Anything else would risk overwriting user data. |
| 7 | **Optional folders** | Not created. README is seeded only when the folder already exists on disk (created later by repos step or manually). | Matches PS. Preserves the "opt-in" property of optional folders. |
| 8 | **`folders.continue` answer key** | An interactive prompt asks "Continue?" before mutating. In unattended mode, `folders.continue: false` skips the whole step (status=skip, exit 0). | Mirrors PS-era `Read-CABConfirm -AnswerKey 'folders.continue'`. |
| 9 | **README content drift between PS and Go copies** | Allowed. The Go copy is the source of truth for the Go wizard going forward. | Avoids a cross-tree sync requirement; the PS code is lame-duck. |
| 10 | **`folders.yaml` location and embed** | Embedded via `//go:embed folders.yaml` from `internal/manifest/`. `$CA_BOOTSTRAP_FOLDERS` env var overrides for tests (same pattern as tools.yaml's `$CA_BOOTSTRAP_MANIFEST`). | Aligned with the existing `tools.yaml` embed precedent. |
| 11 | **`renamed_from` parsing** | Accept scalar OR list. yaml.v3's `Node` API handles the polymorphism; normalise to `[]string` in the parser. | Verbatim port of PS-era's `Get-CABFolderRenamedFrom` semantics. |
| 12 | **`create_folder` reverser refuses non-empty** | Returns `refused` unless `--force` is set. `--force` removes non-empty directories. Top-level workspace root is preserved unless `--include-folders` (PS parlance; in Go alpha.5 this is folded into `--force` since alpha.5 doesn't yet emit workspace-root create entries). | Matches PS's "no surprise deletions" rule. |
| 13 | **`seed_readme` reverser** | Compare current file hash to template hash; remove only on match. Diverged → return `skip` ("README diverged from template; preserving user edits"). | Verbatim port of PS-era's hash discipline. Refusing to remove a user-edited README is the conservative choice. |
| 14 | **README templates embed** | `//go:embed templates/folder-readmes` under `internal/folders/`. Surfaced via `FS()` accessor for tests. | Standard Go embed pattern. |

## 3. Non-goals (explicitly OUT of alpha.5)

- `refresh_readme` (the producer AND its reverser ship later alongside `repair --target folder-readmes`).
- Repo cloning (alpha.6).
- `gh auth login` (alpha.6).
- `--all` mode for `repair --target folders` (deferred to alpha.6+).
- Folder-renamed-from migration via doctor (alpha.6 — `doctor` gains folder-rename drift detection then).
- Workspace-root creation as a journaled action (alpha.7+ when full workspace lifecycle becomes a journal entry; for now identity creates the workspace root un-journaled — alpha.2 behavior preserved).
- TUI (still no).

## 4. Architecture additions on top of alpha.4

### 4.1 New Go packages

```
internal/folders/
    folders.go                                   // Apply(opts) orchestrator
    folders_test.go
    templates/
        folder-readmes/
            ca-tools/README.md
            ca-docs/README.md
            ca-platform/README.md
            cm-product/README.md
            ca-training/README.md
            ca-work-dirs/README.md
            ca-experiments/README.md             // optional folder; seed only if present
            ado-legacy/README.md                 // optional folder; seed only if present
```

### 4.2 Updates to existing packages

- `internal/manifest/`: new `folders.go` adding `type Folder` + `type FoldersManifest` + `LoadFoldersDefault()`. Embeds `folders.yaml` (same dir as existing tools.yaml). `$CA_BOOTSTRAP_FOLDERS` env var override.
- `internal/wizard/steps/folders.go`: new wizard step implementing the `Step` interface. Reads `manifest`, calls `folders.Apply`.
- `internal/cli/setup.go`: register the folders step in the step list, after identity.
- `internal/undo/reversers/`: 4 new reversers — `create_folder.go`, `rename_folder.go`, `remove_empty_folder.go`, `seed_readme.go`.
- `internal/cli/undo.go`: register the 4 new reversers in the dispatch map.
- `internal/undo/undo.go`: extend `matchesTarget` + `categorize` for the new targets (`folders`, `readmes`).

### 4.3 No new external dependencies

Same constraint as alpha.1–4.

## 5. Functional spec — folder creation + renames

### 5.1 Producer flow (one folder at a time)

For each entry in `folders.yaml` where `optional != true`:

1. If `<workspace>/<path>` exists as a directory → kept (no-op).
2. If `<workspace>/<path>` exists but is NOT a directory → fail with "Path '<x>' exists but is not a directory; resolve manually." Exit 1.
3. If `<workspace>/<path>` is absent:
    - Walk `renamed_from` (most-recent → oldest, scalar OR list). First predecessor that exists as a directory at `<workspace>/<predecessor>` is the rename source.
    - **Predecessor exists** → `os.Rename(<predecessor>, <path>)`. Journal `rename_folder` with `before: {from: <predecessor>, to: <path>}`. (Stored in `Before` map for symmetry with `identity_set`'s before/after; the reverser reads `before.from` and `before.to`.)
    - **No predecessor** → `os.MkdirAll(<path>, 0o755)`. Journal `create_folder` with `target: <path>`.
4. After the folder is in place (kept / created / renamed), seed its README per §6.

For each entry where `optional == true`:

1. Only consider folders that already exist on disk.
2. Seed the README per §6. Do not create the folder.

### 5.2 The "continue?" prompt

A single up-front confirm: `Continue?` — answer key `folders.continue`, default yes. Quit → exit 130. No → return without mutating (step status `skip`).

The category preview block (printed before the prompt) mirrors PS-era's icon/color scheme — `✓` for kept, `↻` for will-rename, `+` for will-create, `✗` for collision. In Go ASCII mode (`$CA_BOOTSTRAP_ASCII=1`) substitute `[ok]`, `[ren]`, `[new]`, `[!]`.

## 6. Functional spec — README seeding

### 6.1 Idempotent seed

For folder `<f>`:

1. Locate the template at the embedded path `templates/folder-readmes/<f>/README.md`.
2. If the template is absent → emit a warning (`info` status), return `no-template`.
3. If `<workspace>/<f>/README.md` already exists as a file → return `kept` (do not overwrite).
4. If `<workspace>/<f>/README.md` exists but is NOT a regular file → warn and return `failed`.
5. Copy the embedded bytes to `<workspace>/<f>/README.md`. Journal `seed_readme` with `target: <target-path>`, `before: {template: templates/folder-readmes/<f>/README.md}`.

> The journal's `before.template` field carries the **logical** template path (the embed key), not a filesystem path. The reverser hashes the embedded bytes from the same key to verify the on-disk README still matches what was seeded.

### 6.2 Hash discipline for `seed_readme` reversal

When undo encounters a `seed_readme` entry:

1. Target file missing → `noop`.
2. Template key missing from the embed FS → `skip` ("template no longer at recorded path; preserving file").
3. Hash on-disk file content vs embedded template content:
    - Match → `os.Remove(target)`. Return `ok`.
    - Mismatch → `skip` ("README diverged from template; preserving user edits").
    - Hash computation fails (read error) → `fail`.

## 7. Functional spec — per-action reversers

### 7.1 `create_folder` → `reversers.CreateFolder`

- Target missing → `noop`.
- Target is workspace root (the journal entry's `before` carries `is_workspace_root: true`) AND `--include-folders` NOT set → `skip`.
- Target non-empty AND `--force` NOT set → `refused` ("not empty — use --force to override").
- Otherwise → `os.RemoveAll(target)`, return `ok`.

### 7.2 `rename_folder` → `reversers.RenameFolder`

- `before.to` absent on disk → `noop` ("renamed folder no longer present").
- `before.from` already present on disk → `skip` ("path already exists at original location").
- Otherwise → `os.Rename(before.to, before.from)`, return `ok`.

### 7.3 `remove_empty_folder` → `reversers.RemoveEmptyFolder`

- Producer not in alpha.5 (lands in alpha.6's repos step when a clone fails and leaves an empty group folder). Reverser is included now so the dispatch map is complete when alpha.6 starts emitting these entries.
- Target already exists as directory → `noop`.
- Target exists as non-directory → `skip`.
- Otherwise → `os.MkdirAll(target, 0o755)`, return `ok`.

### 7.4 `seed_readme` → `reversers.SeedReadme`

Per §6.2.

## 8. Acceptance tests (the alpha.5 RED gate)

Hermetic acceptance tests at `tests/acceptance/`. They build the real binary and exercise both `setup` (the producer side) and `undo` (the reverser side). All use `--unattended --config` to avoid interactive stdin.

```go
// ── producer side (setup runs folders step) ──
TestFolders_HappyPath_CreatesAllRequired                  // empty workspace → required folders created, READMEs seeded
TestFolders_Idempotent_KeepsExisting                       // pre-existing required folder → kept, no duplicate journal
TestFolders_OptionalNotCreated                             // optional folder not on disk → not created
TestFolders_OptionalSeedsReadmeIfPresent                   // optional folder pre-created → README seeded
TestFolders_RenamedFrom_Scalar_MigratesPredecessor         // single predecessor → moved into new path
TestFolders_RenamedFrom_List_MigratesMostRecentPredecessor // list with two predecessors, only one exists → moved
TestFolders_RenamedFrom_NoPredecessor_FreshCreate          // no predecessor on disk → fresh create
TestFolders_CollisionNonDirectory_ExitsOne                 // non-dir at required path → exit 1 with clear error
TestFolders_SkipReadmeWhenAlreadyExists                    // README pre-existing in folder → seed kept, not overwritten
TestFolders_ContinueDeclined_ExitsZeroSkip                 // folders.continue: false → step skipped, exit 0
// ── reverser side (undo) ──
TestUndo_CreateFolder_Empty_Removes                        // empty created folder → removed
TestUndo_CreateFolder_NonEmpty_Refused                     // non-empty + no --force → refused, folder remains
TestUndo_CreateFolder_NonEmpty_Force_Removes               // non-empty + --force → removed
TestUndo_RenameFolder_ReverseRename                        // dest exists, source doesn't → rename back
TestUndo_RenameFolder_DestGone_NoOp                        // dest doesn't exist → noop
TestUndo_SeedReadme_TemplateMatch_Removes                  // README hash matches template → removed
TestUndo_SeedReadme_Diverged_Skipped                       // README edited since seed → skip (preserves edits)
TestUndo_RemoveEmptyFolder_Recreates                       // entry present, target absent → recreated
```

Estimated: 18 acceptance + ~10 unit (manifest parser, folder Apply, each reverser).

## 9. Deferred from alpha.5 to subsequent alphas

| Action / feature | Alpha |
|---|---|
| `refresh_readme` producer + reverser | alpha.5.x or alpha.6 (whichever lands `repair --target folder-readmes`) |
| `remove_empty_folder` **producer** | alpha.6 (clone-failure cleanup path) |
| `clone_repo` producer + reverser | alpha.6 |
| `gh_auth_login` producer + reverser | alpha.6 |
| Folder-rename drift detection in `doctor` | alpha.6 |
| `manifest-edit` | alpha.7+ |
| Extras step (workspace file, .vscode defaults, plugin links, workspace-docs, WSL) | alpha.7+ |

## 10. Acceptance criteria for alpha.5

1. ~18 acceptance tests from §8 exist (RED), then pass (GREEN).
2. `go test ./...` clean on all hosts.
3. Cumulative `go test -tags acceptance ./tests/acceptance/...` reports the running PASS count (alpha.1 + alpha.2 + alpha.3 + alpha.4 + alpha.5 ≈ 57).
4. Manual smoke: run `setup` on a fresh sandbox → required folders exist, READMEs seeded. Then `undo --target folders` (or just `undo`) → folders empty → removed (or non-empty → refused with clear message).
5. AB# filed before any code lands. AB#40189.
6. CHANGELOG `Unreleased > Added (Go rewrite — v2.0.0-alpha.5)` entry.
7. `collaboration-workflow.html` status pills evolve: alpha.5 → DONE; alpha.6 → IN PROGRESS or PLANNED.

## 11. References

- alpha.4 spec (immediate predecessor): [`2026-05-28-go-v2-0-alpha-4-spec.md`](2026-05-28-go-v2-0-alpha-4-spec.md)
- Pivot doc: [`2026-05-25-go-rewrite-pivot.md`](2026-05-25-go-rewrite-pivot.md)
- PS-era references:
    - [`legacy/steps/50-folders.ps1`](../../legacy/steps/50-folders.ps1) — producer
    - [`legacy/lib/folders.ps1`](../../legacy/lib/folders.ps1) — `Get-CABFolderRenamedFrom` helper
    - [`legacy/lib/folder-readmes.ps1`](../../legacy/lib/folder-readmes.ps1) — seed_readme helper
    - [`legacy/templates/folder-readmes/`](../../legacy/templates/folder-readmes/) — README template source

> Cross-doc links are correct relative paths; they resolve once the spec lands on `dev`.
