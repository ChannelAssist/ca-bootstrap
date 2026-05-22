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
