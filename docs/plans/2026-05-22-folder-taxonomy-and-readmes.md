# Folder Taxonomy + READMEs + Make/Wiki UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `experiments` → `ca-experiments`, add required `ca-work-dirs/` folder, ship a README template per top-level folder, teach `doctor` + `repair` to handle the rename safely, restyle `make help`, and consolidate the wiki targets into a single `wiki-update`.

**Architecture:** Data-driven via a new `renamed_from:` field in `manifest/folders.yaml`. README templates live in `templates/folder-readmes/` and are copied idempotently by step 50. New repair targets implement the safety contract (never delete non-empty folders or folders with sub-folders without prompts). Make/Wiki changes are pure UX — no behavior change in setup/doctor.

**Tech Stack:** PowerShell 7+ (orchestrator + steps), Pester (tests), bash + pwsh (Make peers), GNU Make + `make.ps1` (task runners), `powershell-yaml` (manifest parser).

**Spec:** `docs/specs/2026-05-22-folder-taxonomy-design.md`

**Work item:** [AB#40007](https://channelassist-inc.visualstudio.com/ChannelManager/_workitems/edit/40007) under Epic AB#38056.

**Branch:** `feature/folder-taxonomy-and-readmes-AB#40007`

---

## File map

### Created

```
docs/
├── plans/2026-05-22-folder-taxonomy-and-readmes.md   (this file)
└── specs/2026-05-22-folder-taxonomy-design.md        (already committed)
templates/
└── folder-readmes/
    ├── ca-tools/README.md
    ├── ca-docs/README.md
    ├── ca-platform/README.md
    ├── cm-product/README.md
    ├── ado-legacy/README.md
    ├── ca-training/README.md
    ├── ca-experiments/README.md
    └── ca-work-dirs/README.md
tests/lib/
├── folders-yaml-grammar.tests.ps1     (renamed_from: round-trip)
├── step50-readme-seed.tests.ps1       (README idempotency)
├── doctor-folder-rename.tests.ps1     (5-row decision table)
├── repair-folder-renames.tests.ps1    (safety contract scenarios)
└── repair-folder-readmes.tests.ps1    (seed / no-op / drift-prompt)
```

### Modified

| Path | Lines |
|---|---|
| `manifest/folders.yaml` | rename `experiments` → `ca-experiments` (+ `renamed_from:`), add `ca-work-dirs` |
| `manifest/repos.yaml` | rename group + repo `into:` path |
| `steps/50-folders.ps1` | seed README from `templates/folder-readmes/<folder>/README.md` on creation |
| `commands/doctor.ps1` | new `folder-rename` check after the `folders` check |
| `commands/repair.ps1` | dispatch for `--target folder-renames`, `--target folder-readmes` |
| `Makefile` | restyle `help` (Keystone-style); drop `wiki-clone`/`wiki-sync`/`wiki-push`; `wiki-update` → `./scripts/wiki-sync.sh full` |
| `make.ps1` | mirror help restyle; drop the three wiki helper functions; `Invoke-WikiUpdate` → `wiki-sync.ps1 full` |
| `scripts/wiki-sync.sh` | new `cmd_full` subcommand (clone-if-missing → sync → push) |
| `scripts/wiki-sync.ps1` | new `Cmd-Full` function (mirror of bash peer) |
| `README.md` | fix stale line 92 folder list |
| `docs/commands.md` | refresh doctor/repair examples mentioning `experiments/` |
| `CHANGELOG.md` | new Unreleased entry |
| `DESIGN.md` | append "Folder taxonomy + README templates" section pointing at the spec |

---

## Task 1: YAML grammar — `renamed_from:` round-trips

Validate that `powershell-yaml` round-trips the new field before relying on it downstream. Likely a no-op (generic YAML), but TDD-prove it so a parser regression doesn't silently break the doctor check.

**Files:**
- Create: `tests/lib/folders-yaml-grammar.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
#requires -Version 7.0
# tests/lib/folders-yaml-grammar.tests.ps1 — `renamed_from:` field round-trips
# through Read-CABManifest. Guards against a parser regression breaking the
# new doctor folder-rename check (AB#40007).

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
}

Describe 'manifest/folders.yaml: renamed_from grammar' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cab-folders-$(Get-Random).yaml"
    }
    AfterEach {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item -Force $script:tmp }
    }

    It 'preserves renamed_from on round-trip' {
        @'
version: 1
root_name: ChannelAssistDev
folders:
  - path: ca-experiments
    description: Internal experiments
    optional: true
    renamed_from: experiments
  - path: ca-work-dirs
    description: Working directories for Claude / Cowork / scratch
'@ | Set-Content -Path $script:tmp -Encoding utf8

        $m = Read-CABManifest -Path $script:tmp -Quiet
        $exp = $m.folders | Where-Object { $_.path -eq 'ca-experiments' } | Select-Object -First 1
        $exp.renamed_from | Should -Be 'experiments'

        $work = $m.folders | Where-Object { $_.path -eq 'ca-work-dirs' } | Select-Object -First 1
        $work.path | Should -Be 'ca-work-dirs'
        # ca-work-dirs is required → absence of optional key reads as null/empty
        [bool]$work.optional | Should -Be $false
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/folders-yaml-grammar.tests.ps1 -Output Detailed"`

Expected: FAIL with "Path /tmp/cab-folders-…yaml not found" or a parser-related error — depends on whether `powershell-yaml` is installed locally. If the test PASSES on first run (likely — the parser is generic), proceed to Step 3 as a no-op commit.

- [ ] **Step 3: No implementation needed**

`renamed_from:` is a plain scalar field; `Read-CABManifest` delegates to `ConvertFrom-Yaml` from `powershell-yaml` which round-trips unknown fields automatically. This test is a regression guard, not driving new code.

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/folders-yaml-grammar.tests.ps1 -Output Detailed"`

Expected: PASS (1 test passed).

- [ ] **Step 5: Commit**

```bash
git add tests/lib/folders-yaml-grammar.tests.ps1
git commit -S -m "test(yaml): guard renamed_from: round-trip in folders.yaml (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Update `manifest/folders.yaml`

Rename `experiments` → `ca-experiments` with `renamed_from:` history; add `ca-work-dirs` as required.

**Files:**
- Modify: `manifest/folders.yaml`

- [ ] **Step 1: Write the failing test**

Append to `tests/lib/folders-yaml-grammar.tests.ps1`:

```powershell
Describe 'manifest/folders.yaml: actual repo manifest' {
    BeforeAll {
        $script:m = Read-CABManifest -Path (Join-Path $script:repoRoot 'manifest/folders.yaml') -Quiet
    }

    It 'no longer has a folder named `experiments`' {
        $hit = $script:m.folders | Where-Object { $_.path -eq 'experiments' }
        $hit | Should -BeNullOrEmpty
    }

    It 'declares ca-experiments with renamed_from: experiments' {
        $f = $script:m.folders | Where-Object { $_.path -eq 'ca-experiments' } | Select-Object -First 1
        $f | Should -Not -BeNullOrEmpty
        $f.renamed_from | Should -Be 'experiments'
        [bool]$f.optional | Should -Be $true
    }

    It 'declares ca-work-dirs as required' {
        $f = $script:m.folders | Where-Object { $_.path -eq 'ca-work-dirs' } | Select-Object -First 1
        $f | Should -Not -BeNullOrEmpty
        [bool]$f.optional | Should -Be $false
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/folders-yaml-grammar.tests.ps1 -Output Detailed"`

Expected: 3 failures in the new Describe block — `experiments` still present, `ca-experiments` absent, `ca-work-dirs` absent.

- [ ] **Step 3: Update the manifest**

Replace the last two folder entries in `manifest/folders.yaml`. After change the full `folders:` block reads:

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
    renamed_from: experiments

  - path: ca-work-dirs
    description: Working directories for Claude Code worktrees, Claude Cowork sessions, and scratch clones
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/folders-yaml-grammar.tests.ps1 -Output Detailed"`

Expected: PASS (4 tests passed total).

- [ ] **Step 5: Commit**

```bash
git add manifest/folders.yaml tests/lib/folders-yaml-grammar.tests.ps1
git commit -S -m "feat(manifest): rename experiments to ca-experiments + add ca-work-dirs (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Update `manifest/repos.yaml`

Rename the group and the `into:` path so step 50 + step 60 stay in sync.

**Files:**
- Modify: `manifest/repos.yaml`

The existing `tests/lib/manifest-consistency.tests.ps1` already asserts every `into:` prefix is in `folders.yaml` — it WILL FAIL once Task 2 is on disk (because `experiments/command-center` no longer has a matching folder). So Task 3 is unblocked by the consistency test failure: that's the failing test for this task.

- [ ] **Step 1: Verify the existing consistency test now fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/manifest-consistency.tests.ps1 -Output Detailed"`

Expected: FAIL — "command-center into=experiments/command-center (prefix 'experiments' not in folders.yaml)".

- [ ] **Step 2: Update `manifest/repos.yaml`**

Edit the `experiments` group at the bottom. After change:

```yaml
  - name: ca-experiments
    description: Internal experiments / prototypes — opt-in, not part of the default workspace
    repos:
      - { repo: ChannelAssist/command-center, into: ca-experiments/command-center, branch: dev, opt_in: true }
```

- [ ] **Step 3: Run the consistency test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/manifest-consistency.tests.ps1 -Output Detailed"`

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add manifest/repos.yaml
git commit -S -m "feat(manifest): rename experiments group to ca-experiments (AB#40007)

Repo into: paths follow the rename; ChannelAssist/command-center now
clones to ca-experiments/command-center.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: README templates for all 8 workspace folders

8 new files. Same shape: title, purpose, what lives here, ASCII tree, safety note (where applicable), refresh instructions.

**Files:**
- Create: `templates/folder-readmes/ca-tools/README.md`
- Create: `templates/folder-readmes/ca-docs/README.md`
- Create: `templates/folder-readmes/ca-platform/README.md`
- Create: `templates/folder-readmes/cm-product/README.md`
- Create: `templates/folder-readmes/ado-legacy/README.md`
- Create: `templates/folder-readmes/ca-training/README.md`
- Create: `templates/folder-readmes/ca-experiments/README.md`
- Create: `templates/folder-readmes/ca-work-dirs/README.md`

- [ ] **Step 1: Create `templates/folder-readmes/ca-tools/README.md`**

```markdown
# ca-tools

ChannelAssist tooling repos. Anything that builds, validates, deploys, or
onboards the rest of the workspace lives here.

## What lives here

- `ca-bootstrap` — the onboarding wizard you used to create this workspace.

## Tree

```
ca-tools/
└── ca-bootstrap/   # interactive setup + doctor + repair + manifest tools
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 2: Create `templates/folder-readmes/ca-docs/README.md`**

```markdown
# ca-docs

ChannelAssist documentation + org-level profile repos. Source-of-truth docs
that ride alongside code lives next to the code; everything cross-cutting
lives here.

## What lives here

- `keystone` — the central engineering knowledge base (ADRs, journal, runbooks).
- `keystone-runtime` — runtime/site for keystone (Astro Starlight).
- `org-profile-public` — `ChannelAssist/.github` (public org README).
- `org-profile-private` — `ChannelAssist/.github-private` (members-only).

## Tree

```
ca-docs/
├── keystone/              # ADRs, engineering journal, runbooks
├── keystone-runtime/      # Astro Starlight site for keystone
├── org-profile-public/    # ChannelAssist/.github
└── org-profile-private/   # ChannelAssist/.github-private (members only)
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 3: Create `templates/folder-readmes/ca-platform/README.md`**

```markdown
# ca-platform

ChannelAssist platform-wide services. Cross-product capabilities that any
business unit can consume — they share the `ca-*` repo prefix.

## What lives here

- `ca-ai-agents` — shared AI agent definitions and prompts.
- `ca-claude-plugin` — the Claude Code plugin (commands, hooks, agents).
- `ca-copilot-plugin` — the GitHub Copilot custom agents + prompts.
- `ca-data-dictionnary-generator` — data-dictionary build tool.
- `ca-privacy-gate` — privacy gateway service.

## Tree

```
ca-platform/
├── ca-ai-agents/
├── ca-claude-plugin/
├── ca-copilot-plugin/
├── ca-data-dictionnary-generator/
└── ca-privacy-gate/
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 4: Create `templates/folder-readmes/cm-product/README.md`**

```markdown
# cm-product

ChannelManager product repos. The application services and shared libraries
that make up the ChannelManager product — they share the `cm-*` prefix.

## What lives here

- `channel-manager` — legacy monolith (≈4 GB; opt-in clone).
- `cm-claims-validator` — claims validation service.
- `cm-contracts` — contract definitions / OpenAPI.
- `cm-currency-service` — currency conversion service.
- `cm-database-infra` — database schema + migrations.
- `cm-platform-infra` — shared platform infrastructure.
- `cm-purchase-order-service` — purchase order service.
- `cm-service-template` — template for new cm-* services.
- `cm-shared-libs` — shared library code.

## Tree

```
cm-product/
├── channel-manager/             # legacy monolith (opt-in, ~4 GB)
├── cm-claims-validator/
├── cm-contracts/
├── cm-currency-service/
├── cm-database-infra/
├── cm-platform-infra/
├── cm-purchase-order-service/
├── cm-service-template/
└── cm-shared-libs/
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 5: Create `templates/folder-readmes/ado-legacy/README.md`**

```markdown
# ado-legacy

Read-only TFVC checkouts of pre-modernization code. Reference-only — do not
commit to anything here.

This folder is **optional** and is only created when you opt in during
`ca-bootstrap.ps1 setup`.

## What lives here

Whatever TFVC mappings you set up against the legacy `channelassist-inc`
Azure DevOps project. Conventional sub-folders mirror the legacy team
project tree (e.g. `Bitnix`, `OldPlatform`, etc.).

## Tree

```
ado-legacy/
├── <legacy-team-project-1>/
└── <legacy-team-project-2>/
```

## Safety

This is a read-only reference. `ca-bootstrap` does not manage its contents
beyond creating the empty folder. If you populate it, those subdirectories
belong to **you and the TFVC mapping** — not to `ca-bootstrap`. The
[safety contract](../../../README.md) applies: ca-bootstrap will not
delete this folder or its contents without an explicit confirmation
prompt.

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 6: Create `templates/folder-readmes/ca-training/README.md`**

```markdown
# ca-training

ChannelAssist training material and learning resources. Repos here are
read-mostly — they're samples, courseware, and reference labs rather than
production services.

## What lives here

- `Generative-AI-for-beginners-dotnet` — Microsoft course fork.
- `agentic-ai-lab` — internal agentic-AI lab + experiments.

## Tree

```
ca-training/
├── Generative-AI-for-beginners-dotnet/
└── agentic-ai-lab/
```

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 7: Create `templates/folder-readmes/ca-experiments/README.md`**

```markdown
# ca-experiments

Internal experiments and prototypes — opt-in, not part of the default
workspace. If you need a place to spike something that's bigger than a
scratch worktree but isn't ready to live under `ca-platform/` or
`cm-product/` yet, this is the home.

This folder is **optional** and is only created when you opt in during
`ca-bootstrap.ps1 setup`.

## What lives here

- `command-center` — opt-in clone of `ChannelAssist/command-center`.

## Tree

```
ca-experiments/
└── command-center/
```

## Safety

If you've added sub-projects under `ca-experiments/` outside the manifest,
they belong to **you** — ca-bootstrap will not delete this folder or its
contents without an explicit confirmation prompt. See the safety contract
in the main README.

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 8: Create `templates/folder-readmes/ca-work-dirs/README.md`**

```markdown
# ca-work-dirs

Working directories for **Claude Code worktrees**, **Claude Cowork sessions**,
and general scratch clones. This is your scratch space — anything that's
ephemeral, parallel to a primary clone, or owned by an AI workflow lives
here.

## When to use it

### Claude Code worktrees

Create a git worktree off any repo to run a parallel Claude Code session on
a separate branch without disturbing your primary clone:

```bash
git -C ../../ca-platform/ca-claude-plugin worktree add \
    ../../ca-work-dirs/ca-claude-plugin-experiment feature/experiment
cd ca-work-dirs/ca-claude-plugin-experiment
claude
```

Convention: worktree path = `<workspace>/ca-work-dirs/<repo>-<topic>/`.

### Claude Cowork

Cowork manages its own sub-folders here. Each Cowork session typically
creates one directory keyed to the run id. **Do not delete sub-folders
under `ca-work-dirs/` without first checking the owning Cowork session —
the contents may be live state.**

### General scratch

Throwaway clones, branch experiments, dependency-bump trials, anything
that doesn't belong under the canonical `ca-*` / `cm-*` folders.

## Tree

```
ca-work-dirs/
├── <repo>-<topic>/        # convention: git worktrees off your primary clones
├── cowork-<run-id>/       # convention: Claude Cowork session work-dirs
└── scratch-*/             # convention: ad-hoc scratch clones
```

(All subdirectories are user/tool-created — none are seeded by ca-bootstrap.)

## Safety

**Do not delete `ca-work-dirs/` or any of its sub-folders without
checking what's inside.** Sub-folders may belong to:

- An active Claude Cowork session.
- A git worktree (deleting it leaves the parent repo's `.git/worktrees/`
  entry stale — use `git worktree remove` instead).
- An IDE-managed scratch checkout.

`ca-bootstrap` honors this and **will not auto-delete this folder or its
contents**. Any repair / undo flow that would remove a non-empty folder
or a folder containing sub-folders requires an explicit confirmation
prompt. See the safety contract in
[`commands.md`](../../../docs/commands.md) for the full rules.

## Refresh

Refresh this README via `ca-bootstrap.ps1 repair --target folder-readmes`.
```

- [ ] **Step 9: Sanity-check the templates exist**

Run: `ls templates/folder-readmes/`

Expected: 8 directories — `ado-legacy ca-docs ca-experiments ca-platform ca-tools ca-training ca-work-dirs cm-product`.

- [ ] **Step 10: Commit**

```bash
git add templates/folder-readmes/
git commit -S -m "feat(templates): add README.md for every top-level workspace folder (AB#40007)

8 README templates (one per folder in manifest/folders.yaml). Step 50 copies
them on folder creation. ca-work-dirs README documents Claude worktrees,
Cowork conventions, and the safety contract for not deleting folders with
sub-folders.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `steps/50-folders.ps1` — seed README on folder creation

Make step 50 copy the README template into each newly-created workspace
folder. Idempotent: only copies when the workspace README does not exist.

**Files:**
- Modify: `steps/50-folders.ps1`
- Create: `tests/lib/step50-readme-seed.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
#requires -Version 7.0
# tests/lib/step50-readme-seed.tests.ps1 — step 50 seeds the README from
# templates/folder-readmes/<folder>/README.md when the folder is created.
# Idempotent: never overwrites a pre-existing README.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/prompts.ps1')
    . (Join-Path $script:repoRoot 'steps/50-folders.ps1')
}

Describe 'Step 50 — README seeding from templates/folder-readmes/' {
    BeforeEach {
        $script:tmpWs = Join-Path ([System.IO.Path]::GetTempPath()) "cab-step50-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-step50-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'

        $script:ctx = @{
            WorkspacePath = $script:tmpWs
            RepoRoot      = $script:repoRoot
            StepOrdinal   = 5
            TotalSteps    = 9
            Answers       = @{ 'folders.continue' = 'y' }
        }
        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
    }
    AfterEach {
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'seeds README.md for every required folder it creates' {
        $result = Invoke-CABStep50 -Context $script:ctx
        $result.status | Should -Be 'ok'

        $required = @('ca-tools', 'ca-docs', 'ca-platform', 'cm-product', 'ca-training', 'ca-work-dirs')
        foreach ($p in $required) {
            $readme = Join-Path $script:tmpWs (Join-Path $p 'README.md')
            Test-Path $readme | Should -BeTrue -Because "$p should have been seeded with a README"
        }
    }

    It 'never overwrites an existing README' {
        $caTools = Join-Path $script:tmpWs 'ca-tools'
        New-Item -ItemType Directory -Path $caTools -Force | Out-Null
        $readme = Join-Path $caTools 'README.md'
        Set-Content -Path $readme -Value '# my hand-edited content' -Encoding utf8

        Invoke-CABStep50 -Context $script:ctx | Out-Null

        Get-Content -Raw $readme | Should -Match 'my hand-edited content'
    }

    It 'records a seed_readme journal entry per seeded README' {
        Invoke-CABStep50 -Context $script:ctx | Out-Null
        Save-CABJournal
        $entries = Get-CABJournalEntry -Action 'seed_readme'
        @($entries).Count | Should -BeGreaterOrEqual 6
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/step50-readme-seed.tests.ps1 -Output Detailed"`

Expected: FAIL — `Test-Path $readme` is false; no seed_readme journal entries.

- [ ] **Step 3: Implement README seeding in step 50**

In `steps/50-folders.ps1`, replace the body of the `foreach ($f in $required)` loop (currently lines ~58-72) with:

```powershell
    $created = 0
    $kept = 0
    $seededReadmes = 0
    foreach ($f in $required) {
        $full = Join-Path $Context.WorkspacePath $f.path
        if (Test-Path $full) {
            $kept++
        } else {
            try {
                [void](New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop)
                Add-CABJournalEntry -Step '50-folders' -Action 'create_folder' -Data @{ path = $full } | Out-Null
                $created++
            } catch {
                return @{ status = 'fail'; details = "Failed to create $full : $($_.Exception.Message)" }
            }
        }

        # Seed README from templates/folder-readmes/<folder>/README.md, idempotently.
        # Source-of-truth path: the template under the repo root, NOT the
        # workspace — workspace READMEs are user-editable.
        $template = Join-Path $Context.RepoRoot (Join-Path 'templates/folder-readmes' (Join-Path $f.path 'README.md'))
        $target   = Join-Path $full 'README.md'
        if ((Test-Path $template) -and -not (Test-Path $target)) {
            try {
                Copy-Item -Path $template -Destination $target -ErrorAction Stop
                Add-CABJournalEntry -Step '50-folders' -Action 'seed_readme' -Data @{
                    path     = $target
                    template = $template
                } | Out-Null
                $seededReadmes++
            } catch {
                # Non-fatal: a missing template should never block setup. Log and continue.
                Write-CABColor Yellow "    ⚠ Could not seed README for $($f.path): $($_.Exception.Message)"
            }
        }
    }

    return @{ status = 'ok'; details = "$created created, $kept kept, $seededReadmes README(s) seeded" }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/step50-readme-seed.tests.ps1 -Output Detailed"`

Expected: PASS (3 tests).

- [ ] **Step 5: Sanity-run the smoke test**

Run: `make smoke`

Expected: `✓ Smoke test passed`. The smoke workspace under `/tmp/cab-smoke-workspace/ChannelAssistDev/` should now contain a `README.md` in every top-level folder.

- [ ] **Step 6: Commit**

```bash
git add steps/50-folders.ps1 tests/lib/step50-readme-seed.tests.ps1
git commit -S -m "feat(setup): seed folder README from templates on creation (AB#40007)

Step 50 now copies templates/folder-readmes/<folder>/README.md into the
workspace alongside the folder it creates. Idempotent — never overwrites
a pre-existing README. Each seed is journaled as a seed_readme action so
undo can reverse them.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `commands/doctor.ps1` — new `folder-rename` check

Add a new check after the existing `folders` check that emits warnings when
the legacy folder is present and `ca-experiments` is not (or when both
present, partial states).

**Files:**
- Modify: `commands/doctor.ps1`
- Create: `tests/lib/doctor-folder-rename.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
#requires -Version 7.0
# tests/lib/doctor-folder-rename.tests.ps1 — doctor's new folder-rename
# check driven by `renamed_from:` in folders.yaml. Covers all 5 rows of
# the decision table in the spec.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'commands/doctor.ps1')
}

Describe 'Doctor — folder-rename check' {
    BeforeEach {
        $script:tmpWs = Join-Path ([System.IO.Path]::GetTempPath()) "cab-doctor-rename-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-doctor-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState

        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
        # Pre-create every required folder + ca-work-dirs so the existing
        # `folders` check doesn't fail and mask the new rename check.
        foreach ($p in 'ca-tools','ca-docs','ca-platform','cm-product','ca-training','ca-work-dirs') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $p) -Force | Out-Null
        }
        # Force the workspace path so doctor doesn't read from the journal.
        $env:CA_BOOTSTRAP_WORKSPACE = $script:tmpWs
        $script:ctx = @{ RepoRoot = $script:repoRoot }
    }
    AfterEach {
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_WORKSPACE -ErrorAction SilentlyContinue
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'omits the check when neither legacy nor new exists' {
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        # No legacy folder + no new folder → status ok (or no row at all).
        if ($hit) { $hit.status | Should -Be 'ok' }
    }

    It 'is silent when only ca-experiments exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        if ($hit) { $hit.status | Should -Be 'ok' }
    }

    It 'warns when only legacy experiments/ exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'experiments') -Force | Out-Null
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit | Should -Not -BeNullOrEmpty
        $hit.status | Should -Be 'warn'
        $hit.fix | Should -Be 'repair --target folder-renames'
    }

    It 'warns when both exist and both are empty' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'experiments')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'warn'
    }

    It 'fails when both exist and at least one has contents' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        $new    = Join-Path $script:tmpWs 'ca-experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        New-Item -ItemType Directory -Path $new    -Force | Out-Null
        Set-Content -Path (Join-Path $legacy 'a.txt') -Value 'x' -Encoding utf8
        Set-Content -Path (Join-Path $new    'b.txt') -Value 'y' -Encoding utf8

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'fail'
        $hit.details | Should -Match 'manual'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/doctor-folder-rename.tests.ps1 -Output Detailed"`

Expected: 3 failures (the three rows that need a check).

- [ ] **Step 3: Implement the doctor check**

In `commands/doctor.ps1`, after the `Folders` block (around line 85, immediately after the `$checks.Add(...)` for the `folders` check), insert:

```powershell
    # ----- Folder renames -----
    # Data-driven from `renamed_from:` in manifest/folders.yaml. Doctor
    # detects drift (legacy folder still present) and points at
    # `repair --target folder-renames` for the safe fix. Repair honors the
    # safety contract: empty legacy → silent rename; non-empty → prompt;
    # both with content → bail to manual.
    if (Test-Path $workspace) {
        $foldersManifest = if ($manifest) { $manifest } else { Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet }
        $renamed = @($foldersManifest.folders | Where-Object { $_.renamed_from })
        foreach ($f in $renamed) {
            $legacyPath = Join-Path $workspace ([string]$f.renamed_from)
            $newPath    = Join-Path $workspace ([string]$f.path)
            $legacyExists = Test-Path $legacyPath -PathType Container
            $newExists    = Test-Path $newPath    -PathType Container

            if (-not $legacyExists) { continue }  # nothing to do; folders check already handles missing-new

            $legacyHasContent = $legacyExists -and (Get-ChildItem -Path $legacyPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            $newHasContent    = $newExists    -and (Get-ChildItem -Path $newPath    -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            $id = "folder-rename:$($f.renamed_from)"

            if (-not $newExists) {
                # Legacy only — straightforward rename.
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'warn'
                    details = "Legacy folder '$($f.renamed_from)/' present, expected '$($f.path)/'."
                    fix     = 'repair --target folder-renames'
                })
            } elseif (-not $legacyHasContent -or -not $newHasContent) {
                # Both exist, but at least one is empty — repair can merge safely.
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'warn'
                    details = "Legacy folder '$($f.renamed_from)/' present alongside '$($f.path)/' — repair will merge."
                    fix     = 'repair --target folder-renames'
                })
            } else {
                # Both have content — bail.
                $checks.Add([ordered]@{
                    id      = $id
                    status  = 'fail'
                    details = "Both '$($f.renamed_from)/' and '$($f.path)/' contain files — manual merge required."
                })
            }
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/doctor-folder-rename.tests.ps1 -Output Detailed"`

Expected: PASS (5 tests).

- [ ] **Step 5: Sanity-run full doctor**

Run: `pwsh -NoLogo -File ./ca-bootstrap.ps1 doctor` (against your real workspace, if any).

Expected: doctor still runs end-to-end. If you have a legacy `experiments/` folder, you should now see a `folder-rename:experiments` warn row pointing at `repair --target folder-renames`.

- [ ] **Step 6: Commit**

```bash
git add commands/doctor.ps1 tests/lib/doctor-folder-rename.tests.ps1
git commit -S -m "feat(doctor): detect renamed folders via renamed_from: manifest field (AB#40007)

New folder-rename:<old> check covers the 5-row decision table from the
spec — silent when only the new path is present, warn for the safe
rename cases, fail when both contain colliding content (manual merge).

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `commands/repair.ps1` — `--target folder-renames`

Implement the safe-rename flow per the safety contract. Empty legacy →
silent `Move-Item`. Non-empty legacy → prompt. Both with content → bail.

**Files:**
- Modify: `commands/repair.ps1`
- Create: `tests/lib/repair-folder-renames.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
#requires -Version 7.0
# tests/lib/repair-folder-renames.tests.ps1 — repair --target folder-renames
# implements the safety contract from the spec.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/prompts.ps1')
    . (Join-Path $script:repoRoot 'commands/repair.ps1')
}

Describe 'Repair — folder-renames' {
    BeforeEach {
        $script:tmpWs = Join-Path ([System.IO.Path]::GetTempPath()) "cab-repair-rename-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-repair-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState
        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
        $script:ctx = @{
            RepoRoot      = $script:repoRoot
            WorkspacePath = $script:tmpWs
            Yes           = $true  # non-interactive — short-circuits prompts on SAFE paths only
        }
    }
    AfterEach {
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'renames an empty legacy folder silently' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'experiments') -Force | Out-Null
        Invoke-CABRepairFolderRenames -Context $script:ctx | Out-Null
        (Test-Path (Join-Path $script:tmpWs 'experiments'))    | Should -BeFalse
        (Test-Path (Join-Path $script:tmpWs 'ca-experiments')) | Should -BeTrue
    }

    It 'is a no-op when neither legacy nor new exists' {
        $r = Invoke-CABRepairFolderRenames -Context $script:ctx
        $r.status | Should -Be 'noop'
    }

    It 'is a no-op when only the new folder exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null
        $r = Invoke-CABRepairFolderRenames -Context $script:ctx
        $r.status | Should -Be 'noop'
    }

    It 'requires confirmation for a non-empty legacy folder (Yes=false)' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        Set-Content -Path (Join-Path $legacy 'a.txt') -Value 'x' -Encoding utf8
        $script:ctx.Yes = $false
        $script:ctx.Answers = @{ 'folder-rename.experiments' = 'n' }

        Invoke-CABRepairFolderRenames -Context $script:ctx | Out-Null
        (Test-Path $legacy) | Should -BeTrue  # not renamed
    }

    It 'renames non-empty legacy when user says yes' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        Set-Content -Path (Join-Path $legacy 'a.txt') -Value 'x' -Encoding utf8
        $script:ctx.Yes = $false
        $script:ctx.Answers = @{ 'folder-rename.experiments' = 'y' }

        Invoke-CABRepairFolderRenames -Context $script:ctx | Out-Null
        (Test-Path $legacy) | Should -BeFalse
        $newF = Join-Path $script:tmpWs 'ca-experiments'
        (Test-Path $newF) | Should -BeTrue
        (Get-Content -Raw (Join-Path $newF 'a.txt')).Trim() | Should -Be 'x'
    }

    It 'never auto-merges when both legacy and new have content' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        $new    = Join-Path $script:tmpWs 'ca-experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        New-Item -ItemType Directory -Path $new    -Force | Out-Null
        Set-Content -Path (Join-Path $legacy 'a.txt') -Value 'x' -Encoding utf8
        Set-Content -Path (Join-Path $new    'b.txt') -Value 'y' -Encoding utf8

        $r = Invoke-CABRepairFolderRenames -Context $script:ctx
        $r.status | Should -Be 'manual'
        # Neither side mutated.
        (Test-Path (Join-Path $legacy 'a.txt')) | Should -BeTrue
        (Test-Path (Join-Path $new    'b.txt')) | Should -BeTrue
    }

    It 'removes an empty legacy when both exist and new is the populated one' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        $new    = Join-Path $script:tmpWs 'ca-experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        New-Item -ItemType Directory -Path $new    -Force | Out-Null
        Set-Content -Path (Join-Path $new 'b.txt') -Value 'y' -Encoding utf8

        $script:ctx.Yes = $false
        $script:ctx.Answers = @{ 'folder-rename.experiments.remove-empty-legacy' = 'y' }

        Invoke-CABRepairFolderRenames -Context $script:ctx | Out-Null
        (Test-Path $legacy) | Should -BeFalse
        (Test-Path (Join-Path $new 'b.txt')) | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/repair-folder-renames.tests.ps1 -Output Detailed"`

Expected: ALL 7 tests fail with "Invoke-CABRepairFolderRenames not recognized".

- [ ] **Step 3: Implement the repair target**

Append to `commands/repair.ps1` (after the existing `Invoke-CABCommandRepair` function, before any trailing code):

```powershell
# Invoke-CABRepairFolderRenames — safety-contract-compliant folder rename.
# Dispatched by `repair --target folder-renames`. Reads `renamed_from:`
# from manifest/folders.yaml and migrates legacy folders to their new
# names per the 5-state table in docs/specs/2026-05-22-folder-taxonomy-design.md.
#
# Returns @{ status = ok|noop|manual|skip; details = '...' }.
function Invoke-CABRepairFolderRenames {
    [CmdletBinding()]
    param([hashtable]$Context)

    $ws = $Context.WorkspacePath
    if (-not $ws -or -not (Test-Path $ws)) {
        return @{ status = 'fail'; details = "Workspace not set or missing: $ws" }
    }

    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet
    $renamed = @($manifest.folders | Where-Object { $_.renamed_from })
    if ($renamed.Count -eq 0) {
        return @{ status = 'noop'; details = 'No folders declare renamed_from:' }
    }

    $touched = 0
    $skipped = 0
    $manuals = New-Object System.Collections.Generic.List[string]

    foreach ($f in $renamed) {
        $legacyPath = Join-Path $ws ([string]$f.renamed_from)
        $newPath    = Join-Path $ws ([string]$f.path)
        $legacyExists = Test-Path $legacyPath -PathType Container
        $newExists    = Test-Path $newPath    -PathType Container

        # No legacy → nothing to migrate.
        if (-not $legacyExists) { continue }

        $legacyChildren = @(Get-ChildItem -Path $legacyPath -Force -ErrorAction SilentlyContinue)
        $newChildren    = if ($newExists) { @(Get-ChildItem -Path $newPath -Force -ErrorAction SilentlyContinue) } else { @() }

        $legacyEmpty = $legacyChildren.Count -eq 0
        $newEmpty    = (-not $newExists) -or ($newChildren.Count -eq 0)

        # State: only legacy, empty → rename silently.
        if (-not $newExists -and $legacyEmpty) {
            Move-Item -Path $legacyPath -Destination $newPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'rename_folder' -Data @{
                from = $legacyPath; to = $newPath; mode = 'silent-empty'
            } | Out-Null
            $touched++
            continue
        }

        # State: only legacy, non-empty → prompt before rename.
        if (-not $newExists -and -not $legacyEmpty) {
            $summary = "$($legacyChildren.Count) entries; first: $(($legacyChildren | Select-Object -First 3 -ExpandProperty Name) -join ', ')"
            $proceed = Read-CABConfirm -Question "Move '$($f.renamed_from)/' → '$($f.path)/' (preserves all contents: $summary)?" `
                                       -Default $true `
                                       -AnswerKey "folder-rename.$($f.renamed_from)"
            if (Test-CABNo $proceed) {
                $skipped++
                continue
            }
            Move-Item -Path $legacyPath -Destination $newPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'rename_folder' -Data @{
                from = $legacyPath; to = $newPath; mode = 'prompted-nonempty'
            } | Out-Null
            $touched++
            continue
        }

        # State: both exist, both empty → remove empty legacy.
        if ($newExists -and $legacyEmpty -and $newEmpty) {
            Remove-Item -Path $legacyPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'remove_empty_folder' -Data @{ path = $legacyPath } | Out-Null
            $touched++
            continue
        }

        # State: both exist, legacy empty + new has content → silent remove of empty legacy.
        if ($newExists -and $legacyEmpty -and -not $newEmpty) {
            Remove-Item -Path $legacyPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'remove_empty_folder' -Data @{ path = $legacyPath; reason = 'new-populated' } | Out-Null
            $touched++
            continue
        }

        # State: both exist, new empty + legacy has content → prompt to move children + remove empty legacy.
        if ($newExists -and $newEmpty -and -not $legacyEmpty) {
            $summary = "$($legacyChildren.Count) entries"
            $proceed = Read-CABConfirm -Question "Move children of '$($f.renamed_from)/' into '$($f.path)/' (then remove empty '$($f.renamed_from)/'): $summary?" `
                                       -Default $true `
                                       -AnswerKey "folder-rename.$($f.renamed_from).remove-empty-legacy"
            if (Test-CABNo $proceed) {
                $skipped++
                continue
            }
            foreach ($child in $legacyChildren) {
                Move-Item -Path $child.FullName -Destination $newPath -Force
            }
            Remove-Item -Path $legacyPath -Force
            Add-CABJournalEntry -Step 'repair' -Action 'rename_folder' -Data @{
                from = $legacyPath; to = $newPath; mode = 'merge-into-empty-new'
            } | Out-Null
            $touched++
            continue
        }

        # State: both exist, both have content → manual merge.
        $manuals.Add("$($f.renamed_from)/ and $($f.path)/ both contain files — inspect, decide which side to keep, then rerun.")
    }

    if ($manuals.Count -gt 0) {
        return @{ status = 'manual'; details = ($manuals -join '; ') }
    }
    if ($touched -eq 0) {
        return @{ status = 'noop'; details = "Nothing to rename (skipped: $skipped)" }
    }
    return @{ status = 'ok'; details = "Renamed/cleaned $touched folder(s); skipped $skipped" }
}
```

Then add a dispatch row in the `switch ($bare)` block (around line 126), after the `'folders'` case:

```powershell
        'folder-renames' {
            $r = Invoke-CABRepairFolderRenames -Context $Context
            Write-CABStatus -Status $(if ($r.status -in 'ok','noop') { 'ok' } elseif ($r.status -eq 'manual') { 'fail' } else { 'warn' }) `
                            -Message $r.details
        }
```

Also update the comment-block target listing near the top:

```powershell
#   --target folder-renames     migrate legacy workspace folders to their renamed paths (safe; honors safety contract)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/repair-folder-renames.tests.ps1 -Output Detailed"`

Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add commands/repair.ps1 tests/lib/repair-folder-renames.tests.ps1
git commit -S -m "feat(repair): add --target folder-renames with safety contract (AB#40007)

Migrates workspace folders that have a renamed_from: declaration to their
new path. Honors the safety contract:
- Empty legacy → silent Move-Item.
- Non-empty legacy → prompt, then Move-Item (preserves all contents).
- Both exist, one empty → safe merge / cleanup.
- Both exist with colliding content → bail with manual-merge guidance,
  never auto-merges.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `commands/repair.ps1` — `--target folder-readmes`

Re-sync README templates to the workspace. Seeds missing READMEs; prompts
before overwriting drifted ones; never `--yes`-bypasses an overwrite.

**Files:**
- Modify: `commands/repair.ps1`
- Create: `tests/lib/repair-folder-readmes.tests.ps1`

- [ ] **Step 1: Write the failing test**

```powershell
#requires -Version 7.0
# tests/lib/repair-folder-readmes.tests.ps1 — repair --target folder-readmes
# re-syncs README templates idempotently and never overwrites without
# explicit user yes.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/prompts.ps1')
    . (Join-Path $script:repoRoot 'commands/repair.ps1')
}

Describe 'Repair — folder-readmes' {
    BeforeEach {
        $script:tmpWs = Join-Path ([System.IO.Path]::GetTempPath()) "cab-repair-readme-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-repair-readme-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState
        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
        foreach ($p in 'ca-tools','ca-docs','ca-platform','cm-product','ca-training','ca-work-dirs') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $p) -Force | Out-Null
        }
        $script:ctx = @{ RepoRoot = $script:repoRoot; WorkspacePath = $script:tmpWs }
    }
    AfterEach {
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'seeds READMEs into folders that are missing them' {
        $r = Invoke-CABRepairFolderReadmes -Context $script:ctx
        $r.status | Should -Be 'ok'
        (Test-Path (Join-Path $script:tmpWs 'ca-tools/README.md')) | Should -BeTrue
    }

    It 'is a no-op when every README already matches the template' {
        Invoke-CABRepairFolderReadmes -Context $script:ctx | Out-Null
        $r = Invoke-CABRepairFolderReadmes -Context $script:ctx
        $r.details | Should -Match 'no-op'
    }

    It 'never overwrites a drifted README without explicit yes' {
        Invoke-CABRepairFolderReadmes -Context $script:ctx | Out-Null
        $drift = Join-Path $script:tmpWs 'ca-tools/README.md'
        Set-Content -Path $drift -Value '# my edits' -Encoding utf8
        $script:ctx.Answers = @{ 'folder-readme.ca-tools.overwrite' = 'n' }

        Invoke-CABRepairFolderReadmes -Context $script:ctx | Out-Null
        (Get-Content -Raw $drift) | Should -Match 'my edits'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/repair-folder-readmes.tests.ps1 -Output Detailed"`

Expected: FAIL — "Invoke-CABRepairFolderReadmes not recognized".

- [ ] **Step 3: Implement the repair target**

Append to `commands/repair.ps1`:

```powershell
# Invoke-CABRepairFolderReadmes — re-sync README templates into workspace.
# Dispatched by `repair --target folder-readmes`. Seeds missing READMEs;
# prompts before overwriting drifted ones. `-Yes` is intentionally NOT
# honored for the overwrite path — operator must consciously confirm.
function Invoke-CABRepairFolderReadmes {
    [CmdletBinding()]
    param([hashtable]$Context)

    $ws = $Context.WorkspacePath
    if (-not $ws -or -not (Test-Path $ws)) {
        return @{ status = 'fail'; details = "Workspace not set or missing: $ws" }
    }

    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet
    $seeded = 0; $overwritten = 0; $skippedDrift = 0; $matched = 0

    foreach ($f in $manifest.folders) {
        $folder = Join-Path $ws ([string]$f.path)
        if (-not (Test-Path $folder -PathType Container)) { continue }

        $template = Join-Path $Context.RepoRoot (Join-Path 'templates/folder-readmes' (Join-Path ([string]$f.path) 'README.md'))
        $target   = Join-Path $folder 'README.md'
        if (-not (Test-Path $template)) { continue }

        if (-not (Test-Path $target)) {
            Copy-Item -Path $template -Destination $target -Force
            Add-CABJournalEntry -Step 'repair' -Action 'seed_readme' -Data @{ path = $target; template = $template } | Out-Null
            $seeded++
            continue
        }

        $templateHash = (Get-FileHash -Path $template -Algorithm SHA256).Hash
        $targetHash   = (Get-FileHash -Path $target   -Algorithm SHA256).Hash
        if ($templateHash -eq $targetHash) {
            $matched++
            continue
        }

        $proceed = Read-CABConfirm -Question "Workspace README at '$($f.path)/README.md' differs from the template. Overwrite?" `
                                   -Default $false `
                                   -AnswerKey "folder-readme.$($f.path).overwrite"
        if (Test-CABNo $proceed) {
            $skippedDrift++
            continue
        }
        Copy-Item -Path $template -Destination $target -Force
        Add-CABJournalEntry -Step 'repair' -Action 'refresh_readme' -Data @{ path = $target; template = $template } | Out-Null
        $overwritten++
    }

    if ($seeded + $overwritten -eq 0) {
        return @{ status = 'ok'; details = "no-op (matched: $matched, drift skipped: $skippedDrift)" }
    }
    return @{ status = 'ok'; details = "seeded $seeded, overwrote $overwritten, matched $matched, drift skipped $skippedDrift" }
}
```

Add a dispatch row in the `switch ($bare)` block, after the `folder-renames` case:

```powershell
        'folder-readmes' {
            $r = Invoke-CABRepairFolderReadmes -Context $Context
            Write-CABStatus -Status ok -Message $r.details
        }
```

Update the top comment block:

```powershell
#   --target folder-readmes     re-sync templates/folder-readmes/ into the workspace
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoLogo -Command "Invoke-Pester -Path ./tests/lib/repair-folder-readmes.tests.ps1 -Output Detailed"`

Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add commands/repair.ps1 tests/lib/repair-folder-readmes.tests.ps1
git commit -S -m "feat(repair): add --target folder-readmes (AB#40007)

Re-syncs templates/folder-readmes/<folder>/README.md into the workspace.
Seeds missing READMEs silently; prompts before overwriting drift, and
intentionally does NOT honor --yes on the overwrite path (templates
require conscious operator confirmation to replace user edits).

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `Makefile` — restyle `help` (Keystone-style)

**Files:**
- Modify: `Makefile`

This is a manual-verify task (visual). No Pester coverage — `make` is the SUT.

- [ ] **Step 1: Add new color codes**

In `Makefile` near line 14-19 (current color block), replace with:

```make
SHELL := /bin/bash
BLUE    := \033[0;34m
GREEN   := \033[0;32m
YELLOW  := \033[0;33m
RED     := \033[0;31m
MAGENTA := \033[0;35m
CYAN    := \033[0;36m
BOLD    := \033[1m
RESET   := \033[0m
```

- [ ] **Step 2: Replace the `help` target**

Replace lines 30-34 with the banner + grouped target:

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

- [ ] **Step 3: Add source dividers between target blocks**

In the same Makefile, ensure each target group is preceded by a `# ━━━` comment header. Replace the existing comment headers (lines 83-87, 155-158, 189-191) with the Keystone-style longer divider:

```make
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tools (per-tool wrappers around repair / undo)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Add dividers above: Tools (`nuke`/`tool-list`), Manifest (`manifest-drift`), Quality (`test`), Smoke (`clean`), Wiki, Releases. Match the existing pattern from lines 155-158 (Wiki sync header already uses a thinner ━ — upgrade those to match Keystone's heavier ━ for consistency).

- [ ] **Step 4: Manual verify**

Run: `make help`

Expected: banner with cyan ━ separators, 7 sections (Workspace / Tools / Manifest / Quality / Smoke & Cleanup / Wiki / Releases), each target listed under its section in yellow. No target appears in two sections; no target is missing.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -S -m "feat(make): restyle help target with Keystone-style sectioned banner (AB#40007)

7 sections (Workspace, Tools, Manifest, Quality, Smoke & Cleanup, Wiki,
Releases) with bold colored headers and ━ source dividers. No behavior
change — every existing target keeps its name and semantics.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `make.ps1` — mirror help restyle

**Files:**
- Modify: `make.ps1`

`make.ps1` already uses `$script:TargetDescriptions` (ordered hashtable). The
help function reads that and prints. Restyle the `Show-Help` printer to match
Keystone's pattern.

- [ ] **Step 1: Find the existing `Show-Help` / help function**

Run: `grep -n "Show-Help\|TargetDescriptions" make.ps1 | head -10`

Expected: locates the section that prints help. Likely around line 90-130 based on layout.

- [ ] **Step 2: Replace the help printer**

Replace whatever `Show-Help`/`Invoke-Help` function currently exists with:

```powershell
function Show-Help {
    $bar = '━' * 81
    Write-Host ''
    Write-Host $bar -ForegroundColor Cyan
    Write-Host '  ca-bootstrap — Available Make Targets' -ForegroundColor Cyan
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''

    $sections = [ordered]@{
        'Workspace'        = @('setup','doctor','repair','undo','nuke','install-commit-hooks')
        'Tools'            = @('tool-list','tool-install','tool-update','tool-remove')
        'Manifest'         = @('manifest-drift','manifest-edit')
        'Quality'          = @('test','lint','format')
        'Smoke & Cleanup'  = @('smoke','smoke-clean','clean')
        'Wiki'             = @('wiki-update')
        'Releases'         = @('release','release-dry-run','release-full','release-full-dry-run','tag')
    }
    foreach ($name in $sections.Keys) {
        Write-Host "${name}:" -ForegroundColor Green
        foreach ($t in $sections[$name]) {
            $desc = $script:TargetDescriptions[$t]
            if (-not $desc) { continue }
            $pad = $t.PadRight(22)
            Write-Host ("  {0} {1}" -f $pad, $desc) -ForegroundColor Yellow
        }
        Write-Host ''
    }
    Write-Host $bar -ForegroundColor Cyan
    Write-Host ''
}
```

- [ ] **Step 3: Manual verify**

Run: `pwsh -NoLogo -File ./make.ps1 help`

Expected: same sectioned layout as `make help`, with the same 7 sections.

- [ ] **Step 4: Commit**

```bash
git add make.ps1
git commit -S -m "feat(make.ps1): mirror Makefile help restyle (AB#40007)

Windows-native peer matches the Keystone-style banner + sections in the
GNU Make peer.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: `Makefile` — consolidate wiki targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Update `wiki-update` to call the script's new `full` directly; remove the other targets**

Replace the entire Wiki sync block (current lines 155-182) with:

```make
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Wiki sync — single "do it all" target. Clones if missing, pulls latest,
# syncs README + DESIGN + docs/, transforms links, regenerates sidebar +
# footer, commits and pushes.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

WIKI_DIR := wiki

.PHONY: wiki-update
wiki-update: ## Clone-if-missing + sync + push the GitHub wiki in one shot
	@printf "$(BLUE)Updating GitHub Wiki...$(RESET)\n"
	@chmod +x scripts/wiki-sync.sh
	@./scripts/wiki-sync.sh full
	@printf "$(GREEN)✓ Wiki updated$(RESET)\n"
```

(Removes `.PHONY: wiki-clone`, `wiki-clone:`, `.PHONY: wiki-sync`, `wiki-sync:`, `.PHONY: wiki-push`, `wiki-push:` — and the prerequisite chain on the old `wiki-update`.)

- [ ] **Step 2: Manual verify**

Run: `make help`

Expected: only `wiki-update` appears under the Wiki section.

Run (from a fresh clone where `./wiki` does not yet exist): `make wiki-update` — should clone, sync, and push in one shot. **Do not actually push during verification** unless you intend to publish; the test is the path-coverage. To dry-run, point `WIKI_DIR` at a temp path or comment out `cmd_push` temporarily.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -S -m "feat(make): collapse wiki-* targets into a single wiki-update (AB#40007)

wiki-clone / wiki-sync / wiki-push removed. wiki-update is now the only
public Make surface for the wiki and calls scripts/wiki-sync.sh full
which handles clone-if-missing + sync + push.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: `make.ps1` — mirror wiki consolidation

**Files:**
- Modify: `make.ps1`

- [ ] **Step 1: Drop the three wiki helper functions; keep only `Invoke-WikiUpdate`**

In `$script:TargetDescriptions`, remove the entries for `wiki-clone`, `wiki-sync`, `wiki-push`. Update `wiki-update` description to `'Clone-if-missing + sync + push the GitHub wiki in one shot'`.

Find each `Invoke-WikiClone`, `Invoke-WikiSync`, `Invoke-WikiPush` function (around lines 405-430 per earlier inspection) and remove them. Replace whatever `Invoke-WikiUpdate` does today with:

```powershell
function Invoke-WikiUpdate {
    Write-Host '[INFO] Updating GitHub Wiki...' -ForegroundColor Blue
    $scriptPath = Join-Path $script:Root 'scripts' 'wiki-sync.ps1'
    & $script:Pwsh -NoLogo -File $scriptPath full
    if ($LASTEXITCODE -ne 0) { throw "wiki-sync.ps1 full failed (exit $LASTEXITCODE)" }
    Write-Host '[OK]   Wiki updated' -ForegroundColor Green
}
```

In the dispatch switch (search for `'wiki-clone'`, `'wiki-sync'`, `'wiki-push'`), delete those `case` branches.

- [ ] **Step 2: Manual verify**

Run: `pwsh -NoLogo -File ./make.ps1 help`

Expected: only `wiki-update` under Wiki section. `pwsh -NoLogo -File ./make.ps1 wiki-clone` should now error with "Unknown target: wiki-clone".

- [ ] **Step 3: Commit**

```bash
git add make.ps1
git commit -S -m "feat(make.ps1): mirror wiki target consolidation (AB#40007)

Windows-native peer drops Invoke-WikiClone / Invoke-WikiSync /
Invoke-WikiPush. wiki-update calls scripts/wiki-sync.ps1 full.

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: `scripts/wiki-sync.sh` — add `cmd_full`

**Files:**
- Modify: `scripts/wiki-sync.sh`

- [ ] **Step 1: Add `cmd_full` between `cmd_push` and `main`**

Insert the new function before the `main()` function:

```bash
# cmd_full — single "do it all" entrypoint. Clones the wiki if absent,
# pulls latest, syncs, and pushes. Called by `make wiki-update`.
cmd_full() {
    if [[ ! -d "$WIKI_DIR/.git" ]]; then
        cmd_clone
    else
        color_blue "Wiki clone exists at $WIKI_DIR; pulling latest..."
        git -C "$WIKI_DIR" fetch --quiet origin
        git -C "$WIKI_DIR" reset --quiet --hard origin/master 2>/dev/null \
            || git -C "$WIKI_DIR" reset --quiet --hard origin/main
    fi
    cmd_sync
    cmd_push
}
```

- [ ] **Step 2: Wire `full` into the dispatcher**

In the `main()` function's `case "$cmd" in` block (around lines 180-192), add a `full)` arm and update the usage strings:

```bash
main() {
    local cmd="${1:-help}"
    case "$cmd" in
        clone) cmd_clone ;;
        sync)  cmd_sync  ;;
        push)  cmd_push  ;;
        full)  cmd_full  ;;
        help|--help|-h)
            echo "Usage: $0 {clone|sync|push|full}"
            ;;
        *)
            color_red "Unknown command: $cmd"
            echo "Usage: $0 {clone|sync|push|full}"
            exit 1
            ;;
    esac
}
```

- [ ] **Step 3: Manual verify**

Run from a clone that does NOT have `./wiki/`: `./scripts/wiki-sync.sh full`

Expected: clones wiki repo, syncs docs, commits, pushes. (To dry-run without pushing, replace `cmd_push` in `cmd_full` with `echo cmd_push` temporarily.)

- [ ] **Step 4: Commit**

```bash
git add scripts/wiki-sync.sh
git commit -S -m "feat(wiki-sync): add full subcommand (clone-if-missing + sync + push) (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: `scripts/wiki-sync.ps1` — mirror `Cmd-Full`

**Files:**
- Modify: `scripts/wiki-sync.ps1`

- [ ] **Step 1: Add `Cmd-Full` and update the dispatcher**

Find the `[ValidateSet('clone', 'sync', 'push', 'help')]` line and change to:

```powershell
    [ValidateSet('clone', 'sync', 'push', 'full', 'help')]
```

Append the new function before the dispatch block:

```powershell
function Cmd-Full {
    if (-not (Test-Path (Join-Path $script:WikiDir '.git'))) {
        Cmd-Clone
    } else {
        Write-Info "Wiki clone exists at $($script:WikiDir); pulling latest..."
        Invoke-Git -Arguments @('-C', $script:WikiDir, 'fetch', '--quiet', 'origin')
        $rc = Invoke-Git -Arguments @('-C', $script:WikiDir, 'reset', '--quiet', '--hard', 'origin/master') -AllowFailure
        if ($rc -ne 0) {
            Invoke-Git -Arguments @('-C', $script:WikiDir, 'reset', '--quiet', '--hard', 'origin/main')
        }
    }
    Cmd-Sync
    Cmd-Push
}
```

In the bottom-of-file dispatcher (the `switch ($Command)` block), add:

```powershell
        'full'  { Cmd-Full }
```

- [ ] **Step 2: Manual verify**

Run: `pwsh -NoLogo -File ./scripts/wiki-sync.ps1 full` from a clean clone.

Expected: same end-to-end behavior as the bash peer.

- [ ] **Step 3: Commit**

```bash
git add scripts/wiki-sync.ps1
git commit -S -m "feat(wiki-sync.ps1): add full subcommand mirroring bash peer (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: `README.md` — fix stale folder list + cross-link spec

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update line 92 of `README.md`**

Replace:

```markdown
6. **Create the folder structure** — `docs/`, `ca-platform/`, `cm-product/`, `ado-legacy/`
```

with:

```markdown
6. **Create the folder structure** — required: `ca-tools/`, `ca-docs/`, `ca-platform/`, `cm-product/`, `ca-training/`, `ca-work-dirs/`; optional (opt-in): `ado-legacy/`, `ca-experiments/`. Every folder gets a generated `README.md` from `templates/folder-readmes/`. See [`docs/specs/2026-05-22-folder-taxonomy-design.md`](docs/specs/2026-05-22-folder-taxonomy-design.md) for the full taxonomy + safety contract.
```

- [ ] **Step 2: Update the make-target list elsewhere in README (if present)**

Run: `grep -n "wiki-clone\|wiki-sync\|wiki-push" README.md`

If matches: replace each with `wiki-update` (or remove the line if it duplicates).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -S -m "docs(readme): refresh stale folder list + drop dropped wiki targets (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: `docs/commands.md` — refresh examples

**Files:**
- Modify: `docs/commands.md`

- [ ] **Step 1: Search for stale references**

Run: `grep -n "experiments\|wiki-clone\|wiki-sync\|wiki-push" docs/commands.md`

- [ ] **Step 2: For each match, decide the rewrite**

- `experiments/` in sample tree → `ca-experiments/`
- `wiki-clone`/`wiki-sync`/`wiki-push` → consolidate to `wiki-update`
- Doctor output examples (line ~115): keep the "4/4 folders present" sample wording but note that the actual folder count is now 8 (or 6 required + 2 optional).

Apply the rewrites verbatim. For the doctor-example block at line ~115, replace any folder count specifically:

```text
Folder structure             ✓  6/6 folders present
```

(6 required: ca-tools, ca-docs, ca-platform, cm-product, ca-training, ca-work-dirs.)

- [ ] **Step 3: Add a short section documenting the two new repair targets**

After the existing `--target identity` row in the repair table (line ~188), add two rows:

```markdown
| `--target folder-renames` | Migrate workspace folders to their renamed paths (safety-contract compliant) |
| `--target folder-readmes` | Re-sync `templates/folder-readmes/` into the workspace (prompts before overwriting drift) |
```

- [ ] **Step 4: Commit**

```bash
git add docs/commands.md
git commit -S -m "docs(commands): refresh examples for ca-experiments + new repair targets (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 17: `CHANGELOG.md` — Unreleased entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add Unreleased section**

Add at the top, under the `# Changelog` header (or wherever the existing Unreleased section lives):

```markdown
## Unreleased

### Added
- Required workspace folder `ca-work-dirs/` for Claude Code worktrees, Claude Cowork sessions, and scratch clones (AB#40007).
- `README.md` template per top-level workspace folder, copied idempotently by step 50 (AB#40007).
- `doctor` check `folder-rename:<old>` driven by new `renamed_from:` field in `folders.yaml` (AB#40007).
- `repair --target folder-renames` migrates workspace folders to their renamed paths per the new safety contract (AB#40007).
- `repair --target folder-readmes` re-syncs README templates with explicit confirmation before overwriting drift (AB#40007).
- `scripts/wiki-sync.sh full` / `scripts/wiki-sync.ps1 full`: single-shot clone-if-missing + sync + push (AB#40007).

### Changed
- Workspace folder `experiments/` renamed to `ca-experiments/` (ADR-0017 `ca-*` convention) (AB#40007).
- `make help` restyled with Keystone-style sectioned banner (Workspace / Tools / Manifest / Quality / Smoke & Cleanup / Wiki / Releases) (AB#40007).
- `wiki-update` is now the single public Make target for wiki sync. `wiki-clone`, `wiki-sync`, `wiki-push` removed (AB#40007).

### Safety contract
- `ca-bootstrap` will never delete a non-empty folder, or any folder containing sub-folders, without explicit user confirmation. Sub-folders may belong to other tools (Claude Cowork, IDE scratch); the rule is enforced across `steps/50-folders.ps1`, `commands/repair.ps1`, and `commands/undo.ps1`.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -S -m "docs(changelog): add Unreleased entry for folder taxonomy + Make/Wiki UX (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 18: `DESIGN.md` — pointer to the spec

**Files:**
- Modify: `DESIGN.md`

- [ ] **Step 1: Append a short section near the end of `DESIGN.md`**

```markdown
### Folder taxonomy + README templates (2026-05)

The workspace folder set is declared in `manifest/folders.yaml`. Every top-level folder receives a `README.md` from `templates/folder-readmes/<folder>/README.md` on creation (step 50), and a per-folder safety contract prevents `ca-bootstrap` from ever deleting a folder that contains sub-folders or non-empty content without explicit user confirmation — sub-folders may belong to other tools (Claude Code worktrees, Claude Cowork sessions, IDE scratch).

Renames are tracked declaratively via a `renamed_from:` field on the folder entry. `doctor` detects drift and points at `repair --target folder-renames`, which performs the migration safely.

Full spec: [`docs/specs/2026-05-22-folder-taxonomy-design.md`](docs/specs/2026-05-22-folder-taxonomy-design.md).
```

- [ ] **Step 2: Commit**

```bash
git add DESIGN.md
git commit -S -m "docs(design): cross-link folder-taxonomy spec (AB#40007)

Refs: AB#40007
Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 19: Smoke + full test suite

**Files:** none (verification only)

- [ ] **Step 1: Clean smoke state**

Run: `make smoke-clean`

- [ ] **Step 2: Run smoke**

Run: `make smoke`

Expected: `✓ Smoke test passed`. Inspect `/tmp/cab-smoke-workspace/ChannelAssistDev/` and verify:

```bash
ls /tmp/cab-smoke-workspace/ChannelAssistDev/
# → ca-docs ca-platform ca-tools ca-training ca-work-dirs cm-product (6 dirs; opt-in folders skipped in hermetic mode)

ls /tmp/cab-smoke-workspace/ChannelAssistDev/ca-tools/README.md
# → exists
```

- [ ] **Step 3: Run full Pester suite**

Run: `make test`

Expected: PASS. New test files (`folders-yaml-grammar`, `step50-readme-seed`, `doctor-folder-rename`, `repair-folder-renames`, `repair-folder-readmes`) all green; no regressions in `manifest-consistency`, `journal`, `tools`, `extras-vscode`, etc.

- [ ] **Step 4: Run lint**

Run: `make lint`

Expected: PASS or known existing warnings only.

- [ ] **Step 5: Manual doctor against the smoke workspace**

```bash
CA_BOOTSTRAP_STATE=/tmp/cab-smoke-state \
CA_BOOTSTRAP_WORKSPACE=/tmp/cab-smoke-workspace/ChannelAssistDev \
pwsh -NoLogo -File ./ca-bootstrap.ps1 doctor
```

Expected: all green (workspace ✓, folders ✓, no `folder-rename:experiments` warn because the smoke workspace was created fresh on the new layout).

- [ ] **Step 6: Manual rename-detection sanity**

```bash
mkdir /tmp/cab-smoke-workspace/ChannelAssistDev/experiments
CA_BOOTSTRAP_STATE=/tmp/cab-smoke-state \
CA_BOOTSTRAP_WORKSPACE=/tmp/cab-smoke-workspace/ChannelAssistDev \
pwsh -NoLogo -File ./ca-bootstrap.ps1 doctor
```

Expected: ⚠ `folder-rename:experiments — Legacy folder 'experiments/' present, expected 'ca-experiments/'. — fix: repair --target folder-renames`.

```bash
CA_BOOTSTRAP_STATE=/tmp/cab-smoke-state \
CA_BOOTSTRAP_WORKSPACE=/tmp/cab-smoke-workspace/ChannelAssistDev \
pwsh -NoLogo -File ./ca-bootstrap.ps1 repair --target folder-renames -Yes
```

Expected: ✓ renamed. Doctor green afterwards.

- [ ] **Step 7: No commit (verification-only task)**

---

## Task 20: Push branch + open PR

**Files:** none

- [ ] **Step 1: Verify branch state**

```bash
git rev-parse --abbrev-ref HEAD       # → feature/folder-taxonomy-and-readmes-AB#40007
git log --oneline origin/dev..HEAD    # → ~18-20 commits, one per logical change
```

- [ ] **Step 2: Push**

```bash
git push -u origin "feature/folder-taxonomy-and-readmes-AB#40007"
```

Expected: branch created on remote.

- [ ] **Step 3: Open PR via `gh`**

```bash
gh pr create --base dev --title "feat: ca-* folder taxonomy + READMEs + Make/Wiki UX (AB#40007)" --body "$(cat <<'EOF'
## Summary

- Rename workspace folder `experiments/` → `ca-experiments/` (ADR-0017 ca-* convention)
- Add required `ca-work-dirs/` folder for Claude Code worktrees / Cowork / scratch
- Ship a README template for every top-level workspace folder (8 total), copied idempotently by step 50
- New `doctor` check `folder-rename:<old>` driven by `renamed_from:` in `folders.yaml`
- New `repair --target folder-renames` (safety-contract compliant) and `repair --target folder-readmes`
- Safety contract: never delete non-empty folders or folders with sub-folders without explicit confirmation
- Restyle `make help` Keystone-style (sectioned banner + colored headers)
- Collapse `wiki-clone`/`wiki-sync`/`wiki-push` into a single `wiki-update`

Full spec: [`docs/specs/2026-05-22-folder-taxonomy-design.md`](docs/specs/2026-05-22-folder-taxonomy-design.md)

## Test plan

- [ ] `make smoke` passes on hermetic fixture
- [ ] `make test` passes (new test files: `folders-yaml-grammar`, `step50-readme-seed`, `doctor-folder-rename`, `repair-folder-renames`, `repair-folder-readmes`)
- [ ] `make lint` clean
- [ ] `make help` renders the new banner layout
- [ ] `make wiki-update` works end-to-end from a clean clone
- [ ] Manual: `doctor` detects legacy `experiments/`; `repair --target folder-renames` migrates safely

Refs: AB#40007

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: Add labels + project board status**

Per global MEMORY.md PR workflow. Replace `<PR_NUMBER>` with the number gh just printed:

```bash
gh pr edit <PR_NUMBER> --add-label "feature,ai-assisted"
# Then the two-step Projects v2 graphql dance (per ca-bootstrap-pbi-conventions.md, board "Internal Tools" #13)
```

- [ ] **Step 5: Move ADO PBI to In Progress**

```bash
az boards work-item update --id 40007 --org https://channelassist-inc.visualstudio.com --state Active
```

- [ ] **Step 6: Update session journal**

Append to the Activity Log + Files Modified sections of the Obsidian session journal. (No commit — journal is in iCloud vault, not git.)

---

## Self-review

### Spec coverage

| Spec section | Plan task |
|---|---|
| 5.1 manifest grammar (`renamed_from:`) | Task 1, 2 |
| 5.2 `manifest/repos.yaml` | Task 3 |
| 5.3 README templates | Task 4 |
| 5.3.1 `ca-work-dirs` README | Task 4 step 8 |
| 5.4 step 50 enhancement | Task 5 |
| 5.5 doctor `folder-rename` check | Task 6 |
| 5.6 `--target folder-renames` | Task 7 |
| 5.7 `--target folder-readmes` | Task 8 |
| 5.8 safety contract (cross-cutting) | Task 7 enforces; CHANGELOG (Task 17) documents |
| 5.9 Make help restyle | Tasks 9 (Makefile), 10 (make.ps1) |
| 5.10 Wiki consolidation | Tasks 11-14 |
| §6 Migration plan | Tasks 6-8 implement; CHANGELOG documents |
| §7 Testing strategy | Tasks 1, 2, 5, 6, 7, 8, 19 |
| §8 Files changed | All tasks |
| README, commands.md, CHANGELOG, DESIGN updates | Tasks 15, 16, 17, 18 |

### Placeholder scan

No "TBD", "implement later", "add appropriate", "similar to Task N", or
descriptive-only steps. Every code step shows the actual code; every command
shows the actual invocation.

### Type consistency

- `Invoke-CABRepairFolderRenames` (Task 7) and `Invoke-CABRepairFolderReadmes` (Task 8) — names used consistently in dispatch table + tests.
- `Cmd-Full` (PowerShell, Task 14) ↔ `cmd_full` (bash, Task 13) — consistent.
- `Show-Help` (make.ps1, Task 10) — used consistently.
- `Add-CABJournalEntry` actions: `create_folder`, `seed_readme`, `rename_folder`, `remove_empty_folder`, `refresh_readme` — used consistently across step 50 + repair.

### Scope check

One PR, ~18-20 commits, each commit a single logical change. Bisectable. The
adjacent Make/Wiki UX changes are small and isolated; bundling does not bloat
the diff materially because the user explicitly asked for "while we're at it".

---

## Execution Handoff

**Plan complete and saved to `docs/plans/2026-05-22-folder-taxonomy-and-readmes.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
