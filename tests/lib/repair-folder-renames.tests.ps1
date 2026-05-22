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

    It 'treats quit (q) as decline-and-stop, never as consent' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        Set-Content -Path (Join-Path $legacy 'a.txt') -Value 'x' -Encoding utf8
        $script:ctx.Yes = $false
        $script:ctx.Answers = @{ 'folder-rename.experiments' = 'q' }

        $r = Invoke-CABRepairFolderRenames -Context $script:ctx
        # quit aborts the entire repair (matches undo.ps1's per-action quit pattern)
        $r.status | Should -Be 'skip'
        (Test-Path $legacy) | Should -BeTrue  # NEVER renamed on quit
    }
}
