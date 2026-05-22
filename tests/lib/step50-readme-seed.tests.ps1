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
