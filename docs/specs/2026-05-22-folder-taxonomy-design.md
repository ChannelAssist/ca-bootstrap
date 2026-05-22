# ca-bootstrap folder taxonomy + READMEs + Make/Wiki UX

- **Date:** 2026-05-22
- **Author:** Peter Giannopoulos (with Claude Code, AI-assisted)
- **Status:** Draft → pending user review
- **Work item:** [AB#40007](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/40007) — child of Epic [AB#38056](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/38056) (AI Platform & Workflow Integration — 2026)
- **Related ADRs:** ADR-0017 (`ca-*` naming prefix), ADR-0023 (canonical 2-tier branch protection)
- **Related work:** [[2026.05.22 - 0738 - Claude Code Session - ca-bootstrap folder taxonomy + READMEs]]

## 1. Summary

Reshape the ca-bootstrap workspace taxonomy so every top-level folder follows the `ca-*` naming convention (ADR-0017), introduce a new required `ca-work-dirs/` folder for Claude Code / Cowork / general scratch workdirs, give every top-level folder a versioned README template, and teach `doctor` to detect the legacy `experiments/` folder name and offer a safe rename via `repair`.

Bake in a **safety contract**: `ca-bootstrap` never deletes a non-empty folder, or any folder containing sub-folders that may belong to other tools, without explicit user confirmation.

Two adjacent UX improvements ride along in the same PR:

- Restyle `make help` to match Keystone's sectioned, color-banded layout (banner, grouped sections, bold colored headers).
- Collapse the four wiki-* targets (`wiki-clone`, `wiki-sync`, `wiki-push`, `wiki-update`) into a single `wiki-update` that handles clone-if-missing + sync + push end-to-end. The dropped targets were thin wrappers around the `scripts/wiki-sync.sh` subcommands; keeping the script's `clone|sync|push` subcommands intact (for internal use) but removing their Makefile surface.

## 2. Goals

### 2.1 Folder taxonomy (primary)

- Rename workspace folder `experiments` → `ca-experiments` everywhere it appears (`manifest/folders.yaml`, `manifest/repos.yaml`, docs, example outputs).
- Add a new required workspace folder `ca-work-dirs` for Claude Code worktrees, Claude Cowork sessions, and general scratch clones.
- Ship a `README.md` template for every top-level workspace folder: purpose paragraph + static ASCII tree of canonical contents. Copied into the workspace by step 50, idempotent (never clobbers user edits).
- Doctor detects the legacy `experiments/` folder name (when `ca-experiments/` is absent) and emits a `warn` with fix command `repair --target folder-renames`.
- `repair --target folder-renames` performs the rename safely per the safety contract (auto for empty, prompted for non-empty, manual-merge bail-out for collision).
- `repair --target folder-readmes` refreshes the README templates from the repo with an explicit prompt (does not run by default).

### 2.2 Make UX (adjacent)

- `make help` (the default goal) renders a banner + sectioned listing identical in style to Keystone (`ca-docs/keystone/Makefile`).
- Sections: **Workspace**, **Tools**, **Manifest**, **Quality**, **Smoke & Cleanup**, **Wiki**, **Releases**.
- Section dividers also appear in the Makefile source between target blocks (matching Keystone's `# ━━━` comment headers).

### 2.3 Wiki consolidation (adjacent)

- `make wiki-update` is the single public target. It clones the wiki if missing, pulls latest, syncs, and pushes — no separate `wiki-clone` / `wiki-sync` / `wiki-push` user-facing targets.
- A new `scripts/wiki-sync.sh full` subcommand drives the end-to-end flow. The existing `clone|sync|push` subcommands stay in the script (called internally by `full`) so the script remains debuggable.

## 3. Non-goals

- No backwards-compatibility shim that mirrors `experiments/` and `ca-experiments/` — clean break, one-shot migration.
- No live-generated ASCII trees — templates are static, refreshable on demand.
- No changes to the `ChannelAssist/command-center` repo itself (only its `into:` path in `manifest/repos.yaml`).
- No changes to `gh` tooling — already present in `manifest/tools.yaml` as required.
- No renaming of any other workspace folders — only `experiments` → `ca-experiments` and the new `ca-work-dirs`. Other folders (`ca-tools`, `ca-docs`, `ca-platform`, `cm-product`, `ado-legacy`, `ca-training`) already follow conventions and are out of scope.
- No changes to the workspace root default (`ChannelAssistDev`).

## 4. Context

### 4.1 Current taxonomy (`manifest/folders.yaml`)

```yaml
folders:
  - { path: ca-tools }
  - { path: ca-docs }
  - { path: ca-platform }
  - { path: cm-product }
  - { path: ado-legacy,  optional: true }
  - { path: ca-training }
  - { path: experiments, optional: true }   # ← rename target
```

### 4.2 Current repo grouping (`manifest/repos.yaml`)

```yaml
groups:
  - name: experiments
    repos:
      - { repo: ChannelAssist/command-center, into: experiments/command-center, opt_in: true }
```

### 4.3 Doctor architecture (`commands/doctor.ps1`)

Existing checks: `workspace`, `folders` (presence of required folders), per-tool checks, `gh-auth`, `repos`, `git-identity`, `journal`. The `folders` check fails when an expected folder is absent, but has no concept of *renamed* folders.

### 4.4 Folder creation (`steps/50-folders.ps1`)

Reads `manifest/folders.yaml`, mkdirs missing folders, journals every creation under action `create_folder`. Idempotent. Today: creates only the directory; does not seed a README.

## 5. Design

### 5.1 Manifest grammar additions (`manifest/folders.yaml`)

```yaml
folders:
  - path: ca-tools
    description: ChannelAssist tooling repos (ca-bootstrap and friends)

  - path: ca-docs
    description: ChannelAssist documentation + org profiles (Keystone, .github)

  - path: ca-platform
    description: ChannelAssist platform-wide services (ca-* prefix)

  - path: cm-product
    description: ChannelManager product repos (cm-* prefix)

  - path: ado-legacy
    description: Legacy TFVC checkouts of pre-modernization code (read-only reference)
    optional: true

  - path: ca-training
    description: ChannelAssist training material and learning resources

  - path: ca-experiments
    description: Internal experiments / prototypes (opt-in; sparse on disk by default)
    optional: true
    renamed_from: experiments       # ← NEW: legacy path for doctor rename detection

  - path: ca-work-dirs
    description: Working directories for Claude Code worktrees, Claude Cowork sessions, and scratch clones
    # required (no `optional: true`)
```

**New field semantics:**

- `renamed_from: <legacy-path>` — declares that a folder was previously named `<legacy-path>`. Doctor uses this to detect drift; repair uses it to plan a safe rename. Multi-valued form (a list) is **out of scope** for this iteration — one rename history per folder is sufficient.

### 5.2 Repo manifest update (`manifest/repos.yaml`)

Rename group + repo `into:` path:

```yaml
groups:
  - name: ca-experiments                                    # was: experiments
    description: Internal experiments / prototypes — opt-in, not part of the default workspace
    repos:
      - { repo: ChannelAssist/command-center, into: ca-experiments/command-center, ... }   # was: experiments/command-center
```

### 5.3 Template directory (`templates/folder-readmes/`)

New tree:

```
templates/
├── folder-readmes/
│   ├── ca-tools/README.md
│   ├── ca-docs/README.md
│   ├── ca-platform/README.md
│   ├── cm-product/README.md
│   ├── ado-legacy/README.md
│   ├── ca-training/README.md
│   ├── ca-experiments/README.md
│   └── ca-work-dirs/README.md
└── (existing templates …)
```

Each README:

1. **Title** — folder name.
2. **Purpose** — one or two sentences pulled from the manifest `description:` (but more readable).
3. **What lives here** — bulleted list of canonical contents (repos for code folders; conventions for `ca-work-dirs`).
4. **ASCII tree** — static, hand-written, reflecting the canonical contents at time of writing. Source of truth is `manifest/repos.yaml`.
5. **Safety note** — for `ca-work-dirs` and any folder with sub-folders, a "ca-bootstrap will not delete this folder without confirmation; contents may belong to other tools" callout.
6. **Refresh instructions** — short line: "Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`."

#### 5.3.1 `ca-work-dirs/README.md` content scope

Beyond the standard skeleton, this README covers:

- **Claude Code worktrees** — how to use `git worktree add` to spawn parallel Claude sessions on the same repo. Convention: worktree path = `<workspace>/ca-work-dirs/<repo>-<topic>/`.
- **Claude Cowork sessions** — Cowork creates its own subdirectories here. **Do not delete `ca-work-dirs/` or its sub-folders without first checking what's inside** (they may be active Cowork state).
- **General scratch / experimental clones** — throwaway clones, branch experiments, anything that doesn't belong under `ca-platform/` or `cm-product/`.
- **Conventions** — naming (`<repo>-<topic>`), cleanup discipline (delete when done, but verify with the owning tool first), `.gitignore` (the folder itself is ignored by the workspace `.vscode/settings.json` so it doesn't pollute search).

### 5.4 Step 50 enhancement (`steps/50-folders.ps1`)

After `New-Item -ItemType Directory`, look up the matching template at `templates/folder-readmes/<folder>/README.md`. If found AND the workspace target `<workspace>/<folder>/README.md` does **not** exist, copy it. Journal a new action `seed_readme` per file. Never overwrites existing READMEs.

### 5.5 Doctor: new `folder-rename` check (`commands/doctor.ps1`)

After the existing `folders` check, iterate folders that declare `renamed_from:`:

| `<workspace>/<old>` exists | `<workspace>/<new>` exists | Status | Details | Fix |
|---|---|---|---|---|
| no  | yes | `ok`   | (skip — current state is correct) | — |
| no  | no  | `ok`   | (no folder yet — `folders` check already covers absent required folders) | — |
| yes | no  | `warn` | "Legacy folder `<old>/` present, expected `<new>/`. Will rename via repair." | `repair --target folder-renames` |
| yes | yes, **at least one empty** | `warn` | "Legacy folder `<old>/` present alongside `<new>/` — repair will merge." | `repair --target folder-renames` |
| yes | yes, **both contain files** | `fail` | "Both `<old>/` and `<new>/` contain files — manual merge required." | (no auto-fix; manual instructions in repair output) |

### 5.6 Repair: `--target folder-renames` (`commands/repair.ps1`)

Behavior, per the safety contract:

1. Read folders with `renamed_from:` from `manifest/folders.yaml`.
2. For each (legacy, new) pair:
   - **Both absent** → no-op.
   - **Only new present** → no-op.
   - **Only legacy present, empty** → `Move-Item` legacy → new. Journal `rename_folder` action.
   - **Only legacy present, non-empty** → prompt: *"Move `<old>/` → `<new>/` (preserves all contents)? [Y/n]"*. On yes, `Move-Item` (atomic on same volume). Journal action. On no, skip and report.
   - **Both present, legacy empty** → remove empty legacy (after confirm). Journal `remove_empty_folder`. New is already correct.
   - **Both present, new empty + legacy non-empty** → prompt: *"Move children of `<old>/` into `<new>/`, then remove empty `<old>/`? [Y/n]"*. On yes, move each child (per-child prompts elided in default mode; `--interactive` shows per-child). On no, skip and report.
   - **Both present, both have content** → never auto-fix. Print the conflicting paths and bail with a manual-merge message: *"Both `<old>/` and `<new>/` contain files. Resolve manually: inspect contents, decide which side to keep, then rerun doctor."*
3. `-Yes` / `--yes` flag skips prompts but only on the safe paths (empty legacy, no collision). Never silently merges or deletes non-empty content.

### 5.7 Repair: `--target folder-readmes` (`commands/repair.ps1`)

Behavior:

1. For each folder in `manifest/folders.yaml` that exists on disk:
   - If the workspace README does not exist → copy template, journal `seed_readme`.
   - If it exists and matches the template byte-for-byte → no-op.
   - If it exists and differs → prompt: *"`<folder>/README.md` differs from the template. Show diff? [y/N]"* then *"Overwrite? [y/N]"*. Never overwrites without explicit yes. `--yes` is disallowed for this target (templates intentionally require human-confirmation to overwrite).
2. Journal `refresh_readme` for each overwrite.

### 5.8 Safety contract (cross-cutting)

This applies to every code path in ca-bootstrap that mutates workspace folders (`steps/50-folders.ps1`, `commands/repair.ps1`, `commands/undo.ps1`):

1. **Never delete a non-empty folder** without an explicit confirmation prompt.
2. **Never delete a folder that contains sub-folders** without a confirmation prompt, regardless of file count — sub-folders may belong to other tools (Claude Cowork sessions, IDE scratch, experimental clones).
3. **Empty leaf folders** may be removed as part of an automated fix.
4. **Confirmation prompts** must show the folder path AND a one-line summary of its contents (file count + first few names) so the user can make an informed choice.
5. `-Yes` / `--yes` bypasses prompts only on the safe paths (empty folder, no collision). It does NOT bypass non-empty-folder confirmations.
6. **Journal** every destructive action (rename, remove) with enough context to undo.

The existing `undo --include-folders` flag is already on the right side of this contract for empty folders; this design extends the same posture to the new repair targets.

### 5.9 Make help restyle

Adopt Keystone's pattern from `ca-docs/keystone/Makefile`:

1. **Color palette** — add `MAGENTA`, `CYAN`, `BOLD` to the existing `BLUE/GREEN/YELLOW/RED/RESET` set.
2. **`help` target** — replace the single-pass `grep | awk` with a banner + per-section awk filter:

```make
.PHONY: help
help: ## Show this help (default target)
	@echo ""
	@echo "$(BOLD)$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(RESET)"
	@echo "$(BOLD)$(CYAN)  ca-bootstrap — Available Make Targets$(RESET)"
	@echo "$(BOLD)$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(RESET)"
	@echo ""
	@echo "$(BOLD)$(GREEN)Workspace:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; $$1 == "setup" || $$1 == "doctor" || $$1 == "repair" || $$1 == "undo" || $$1 == "nuke" || $$1 == "install-commit-hooks" {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(BLUE)Tools:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; /^tool-/ {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(BLUE)Manifest:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; /^manifest-/ {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(GREEN)Quality:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; $$1 == "test" || $$1 == "lint" || $$1 == "format" {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Smoke & Cleanup:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; /^smoke/ || $$1 == "clean" {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(CYAN)Wiki:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; /^wiki/ {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(MAGENTA)Releases:$(RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; /^release/ || $$1 == "tag" {printf "  $(YELLOW)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(RESET)"
	@echo ""
```

3. **Source dividers** — between each section's target block, add the same `# ━━━` Keystone-style comment headers so the Makefile source mirrors the help output.
4. **No behavior change** — only formatting. Every existing target keeps its name, semantics, and `## help-text` annotation. The grep+awk filter is exact-match where possible (`$$1 == "setup"`) and prefix-match where natural (`/^tool-/`, `/^manifest-/`).

### 5.10 Wiki consolidation

Public Makefile surface (after):

| Target | Description |
|---|---|
| `wiki-update` | Single "do it all" target. Clones the wiki if absent, pulls latest, syncs from README + DESIGN + docs/, transforms links, regenerates sidebar + footer, commits and pushes. No prerequisites. |

Targets **removed**: `wiki-clone`, `wiki-sync`, `wiki-push`.

New script subcommand in `scripts/wiki-sync.sh` (and the PowerShell peer `scripts/wiki-sync.ps1`):

```bash
cmd_full() {
    # 1. Ensure wiki clone exists
    if [[ ! -d "$WIKI_DIR/.git" ]]; then
        cmd_clone
    else
        color_blue "Wiki clone exists; pulling latest..."
        git -C "$WIKI_DIR" fetch --quiet origin
        git -C "$WIKI_DIR" reset --quiet --hard origin/master 2>/dev/null \
            || git -C "$WIKI_DIR" reset --quiet --hard origin/main
    fi

    # 2. Sync (existing function — unchanged)
    cmd_sync

    # 3. Push (existing function — unchanged, with reconcile-on-divergence)
    cmd_push
}
```

The internal `clone|sync|push` subcommands stay in the script — they're called by `full` and remain useful for ad-hoc debugging (`./scripts/wiki-sync.sh sync` to preview without pushing). Only the **Makefile surface** is consolidated; the script API stays composable.

**Failure modes:**

- Wiki not yet initialized on GitHub → existing `cmd_clone` error message stays (link to create the first wiki page, then re-run).
- Push divergence → existing `cmd_push` retry-on-divergence pattern (per Keystone ADR 013) stays.
- No changes since last push → `cmd_push` already returns 0 with "No wiki changes to push" — kept.

**Footer text update:** the existing footer says *"Edit source under `docs/` and run `make wiki-update`"* — already correct, no change.

## 6. Migration plan

For existing operators (people who already ran `setup` on an older ca-bootstrap):

1. Pull the new ca-bootstrap (`make` updates from main, or fresh clone).
2. Run `ca-bootstrap.ps1 doctor` — sees `folder-rename` warn for `experiments/` → `ca-experiments/` (if their workspace had it).
3. Run `ca-bootstrap.ps1 repair --target folder-renames` — interactive rename per safety contract.
4. Run `ca-bootstrap.ps1 repair --target folder-readmes` (optional) — seeds READMEs into existing folders.

For new operators, `setup` does all of this in step 50 from scratch — no migration needed.

## 7. Testing strategy

### 7.1 Unit tests (Pester)

- `Read-CABManifest` round-trips the new `renamed_from:` field.
- `Test-CABStep50` does not regress for the existing folder set; new `ca-work-dirs` is treated as required.
- README copy logic in step 50: copies when absent, skips when present, journals correctly.

### 7.2 Doctor check tests

- All five rows of the rename-detection table (5.5) produce the expected `status` and `fix` fields.

### 7.3 Repair tests

- `--target folder-renames` against:
  - Empty legacy only → renames silently.
  - Non-empty legacy only → prompts (`-Yes` short-circuits).
  - Both empty → removes empty legacy.
  - Both with content → bails out with manual-merge message.
- `--target folder-readmes` against:
  - Missing READMEs → seeds.
  - Matching READMEs → no-op.
  - Drifted READMEs → prompts; never overwrites without yes.

### 7.4 Smoke test

End-to-end: fresh workspace, run `setup`, confirm all 8 top-level folders + all 8 READMEs exist, then `doctor` reports green.

## 8. Files changed (summary)

| Path | Change |
|---|---|
| `manifest/folders.yaml` | rename `experiments` → `ca-experiments` (add `renamed_from:`); add `ca-work-dirs` required entry |
| `manifest/repos.yaml` | rename group + `into:` path for `command-center` |
| `templates/folder-readmes/ca-tools/README.md` | new |
| `templates/folder-readmes/ca-docs/README.md` | new |
| `templates/folder-readmes/ca-platform/README.md` | new |
| `templates/folder-readmes/cm-product/README.md` | new |
| `templates/folder-readmes/ado-legacy/README.md` | new |
| `templates/folder-readmes/ca-training/README.md` | new |
| `templates/folder-readmes/ca-experiments/README.md` | new |
| `templates/folder-readmes/ca-work-dirs/README.md` | new (includes safety note + Cowork conventions) |
| `steps/50-folders.ps1` | seed README on folder creation (idempotent) |
| `commands/doctor.ps1` | new `folder-rename` check driven by `renamed_from:` |
| `commands/repair.ps1` | new `--target folder-renames`; new `--target folder-readmes` |
| `commands/undo.ps1` | verify safety contract still holds (`--include-folders` already respects it) |
| `lib/yaml.ps1` | ensure `renamed_from:` survives roundtrip |
| `tests/manifest.Tests.ps1` | grammar tests |
| `tests/doctor.Tests.ps1` | rename-detection table tests |
| `tests/repair.Tests.ps1` | new tests for both repair targets |
| `README.md` | fix stale line 92 (4-folder list); add ca-work-dirs / ca-experiments references |
| `docs/commands.md` | update `doctor`/`repair` example outputs |
| `CHANGELOG.md` | new entry under Unreleased |
| `DESIGN.md` | append a short section pointing to this spec |
| `Makefile` | restyle `help` target (banner + sections); remove `wiki-clone`/`wiki-sync`/`wiki-push`; `wiki-update` calls `./scripts/wiki-sync.sh full` directly |
| `make.ps1` | mirror the Makefile help restyle + wiki consolidation (Windows peer must stay in sync) |
| `scripts/wiki-sync.sh` | add `cmd_full` subcommand (clone-if-missing + sync + push) |
| `scripts/wiki-sync.ps1` | mirror `cmd_full` in the PowerShell peer |

## 9. Open questions

None — all design questions resolved with Peter before this doc was written. Surfaced during brainstorming:

- *Is `gh` already installed?* Yes (confirmed) — no-op.
- *Required or optional `ca-work-dirs`?* Required.
- *Where do READMEs live?* In-repo templates, copied on folder creation.
- *Static or generated ASCII trees?* Static.
- *What's the rename rollback story?* Doctor + repair as designed; safety contract prevents data loss; manifest history is the audit trail.

## 10. Out of scope (deferred)

- Live-generated trees driven by `manifest/repos.yaml` — could be a follow-up `repair --target folder-tree-refresh` if drift becomes a recurring issue.
- A `SessionStart` hook in `~/.claude/settings.json` that auto-creates the Obsidian engineering journal skeleton — separate concern, tracked in the session journal's Insights section.
- Renaming any other workspace folders (e.g., `ado-legacy` → `ca-ado-legacy`). Stay focused.
- Multi-step rename histories (`renamed_from:` as a list). Add when a second rename happens.
