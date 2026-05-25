#requires -Version 7.0
# tests/lib/folders-renamed-from.tests.ps1 — guards `renamed_from:`
# support in manifest/folders.yaml.
#
# Two surfaces under test:
#   1. Get-CABFolderRenamedFrom normalises scalar / list / missing.
#   2. Invoke-CABStep50 renames an existing predecessor into the new
#      path (walking the chain most-recent → oldest) instead of
#      creating an empty folder.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/prompts.ps1')
    . (Join-Path $script:repoRoot 'lib/folders.ps1')
    . (Join-Path $script:repoRoot 'steps/50-folders.ps1')
}

Describe 'Get-CABFolderRenamedFrom — normalisation' {
    # Helper returns are always consumed via @(...) at call sites (the
    # PowerShell idiom for "treat result as array regardless of arity"),
    # so these tests mirror that contract — bare `Get-CABFolderRenamedFrom`
    # may unwrap a single-element result to a scalar, which is by design.

    It 'returns empty when renamed_from is absent' {
        $r = @(Get-CABFolderRenamedFrom -Folder @{ path = 'ca-tools' })
        $r.Count | Should -Be 0
    }

    It 'wraps a scalar value into a single-element array' {
        $r = @(Get-CABFolderRenamedFrom -Folder @{ path = 'ca-prototypes'; renamed_from = 'ca-experiments' })
        $r.Count | Should -Be 1
        $r[0]    | Should -Be 'ca-experiments'
    }

    It 'preserves a list in declared order (most-recent → oldest)' {
        $r = @(Get-CABFolderRenamedFrom -Folder @{
            path         = 'ca-prototypes'
            renamed_from = @('ca-experiments','experiments')
        })
        $r.Count | Should -Be 2
        $r[0]    | Should -Be 'ca-experiments'
        $r[1]    | Should -Be 'experiments'
    }

    It 'drops nulls and empty strings' {
        $r = @(Get-CABFolderRenamedFrom -Folder @{
            path         = 'ca-prototypes'
            renamed_from = @('ca-experiments', '', $null, '  ', 'experiments')
        })
        $r.Count | Should -Be 2
        $r[0]    | Should -Be 'ca-experiments'
        $r[1]    | Should -Be 'experiments'
    }

    It 'accepts PSCustomObject input as well as hashtables' {
        $obj = [pscustomobject]@{ path = 'ca-prototypes'; renamed_from = 'ca-experiments' }
        $r = @(Get-CABFolderRenamedFrom -Folder $obj)
        $r.Count | Should -Be 1
        $r[0]    | Should -Be 'ca-experiments'
    }

    It 'treats an empty scalar as no history' {
        $r = @(Get-CABFolderRenamedFrom -Folder @{ path = 'a'; renamed_from = '   ' })
        $r.Count | Should -Be 0
    }
}

Describe 'Invoke-CABStep50 — walks renamed_from chain' {
    BeforeEach {
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-folders-rename-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:tempHome -Force | Out-Null
        $script:workspace = Join-Path $script:tempHome 'ws'
        New-Item -ItemType Directory -Path $script:workspace -Force | Out-Null

        # Point the journal at a per-test temp dir so we don't touch
        # ~/.ca-bootstrap, then open an active session — Add-CABJournalEntry
        # throws without one.
        $env:CA_BOOTSTRAP_STATE = $script:tempHome
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test' | Out-Null

        Set-CABPromptMode -Unattended $true -Answers @{ 'folders.continue' = $true }

        # Stub the manifest read so the test is hermetic — no
        # powershell-yaml dependency and no coupling to the live
        # folders.yaml shipping with the repo. Defined at global
        # scope so step 50 (a different script scope) resolves it.
        function global:Read-CABManifest { param($Path, [switch]$Quiet)
            @{
                folders = @(
                    @{ path = 'ca-prototypes'; description = 'demo'; renamed_from = @('ca-experiments','experiments') }
                )
            }
        }
    }

    AfterEach {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose 'no transcript' }
        Set-CABPromptMode -Unattended $false -Answers @{}
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        Remove-Item function:global:Read-CABManifest -ErrorAction SilentlyContinue
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item -LiteralPath $script:tempHome -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'renames the most-recent existing predecessor into the new path' {
        # Seed: previous-rename folder + a sentinel file inside it.
        New-Item -ItemType Directory -Path (Join-Path $workspace 'ca-experiments') | Out-Null
        Set-Content -Path (Join-Path $workspace 'ca-experiments/README.md') -Value 'keep me'

        $r = Invoke-CABStep50 -Context @{
            RepoRoot = $repoRoot; WorkspacePath = $workspace; TotalSteps = 8
        }

        $r.status | Should -Be 'ok'
        $r.details | Should -Match 'renamed'
        Test-Path (Join-Path $workspace 'ca-prototypes')           | Should -BeTrue
        Test-Path (Join-Path $workspace 'ca-prototypes/README.md') | Should -BeTrue
        Test-Path (Join-Path $workspace 'ca-experiments')          | Should -BeFalse
    }

    It 'falls back to the oldest predecessor when the most-recent is absent' {
        # Operator skipped the first migration: only `experiments` on disk.
        New-Item -ItemType Directory -Path (Join-Path $workspace 'experiments') | Out-Null
        Set-Content -Path (Join-Path $workspace 'experiments/notes.txt') -Value 'kept'

        $r = Invoke-CABStep50 -Context @{
            RepoRoot = $repoRoot; WorkspacePath = $workspace; TotalSteps = 8
        }

        $r.status | Should -Be 'ok'
        Test-Path (Join-Path $workspace 'ca-prototypes/notes.txt') | Should -BeTrue
        Test-Path (Join-Path $workspace 'experiments')             | Should -BeFalse
    }

    It 'creates a fresh folder when no predecessor exists on disk' {
        $r = Invoke-CABStep50 -Context @{
            RepoRoot = $repoRoot; WorkspacePath = $workspace; TotalSteps = 8
        }

        $r.status | Should -Be 'ok'
        $r.details | Should -Not -Match 'renamed'
        Test-Path (Join-Path $workspace 'ca-prototypes') | Should -BeTrue
    }

    It 'Test-CABStep50 reports a collision (not a pending rename) when a regular file sits at the required path' {
        # PR #82 cycle-2 review pinned: a regular file squatting on
        # the required path used to be collapsed into the "missing"
        # bucket via -PathType Container, then the predecessor walk
        # would render "↻ rename predecessor → required-path" in
        # both the preview and the diagnostic. But Invoke-CABStep50
        # would have failed at this row with "exists but is not a
        # directory" before the rename ever fired — preview and
        # action diverged.
        #
        # Both the preview (Invoke-CABStep50 row rendering) and the
        # diagnostic (Test-CABStep50) now distinguish the collision
        # bucket explicitly. This test exercises Test-CABStep50.
        Set-Content -Path (Join-Path $workspace 'ca-prototypes') -Value 'not a directory'
        # Add a predecessor directory to confirm the collision wins
        # over the predecessor-walk path.
        New-Item -ItemType Directory -Path (Join-Path $workspace 'ca-experiments') | Out-Null

        $r = Test-CABStep50 -Context @{
            RepoRoot = $repoRoot; WorkspacePath = $workspace
        }
        $r.status | Should -Be 'pending'
        $r.details | Should -Match 'collision'
        $r.details | Should -Match 'ca-prototypes'
        # Must NOT misclassify as a pending rename.
        $r.details | Should -Not -Match 'ca-experiments\s*→'
    }
}
