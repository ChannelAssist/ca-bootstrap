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
    # PR #82 wired Get-CABFolderRenamedFrom into step 50's preview
    # block and create-or-rename branch. The orchestrator loads
    # lib/folders.ps1 alongside the rest of lib/; tests that exercise
    # step 50 directly must dot-source it explicitly.
    . (Join-Path $script:repoRoot 'lib/folders.ps1')
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
        # Release transcript handle + session lock so temp dirs can be removed on Windows.
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "No active transcript to stop." }
        try { Unlock-CABSession } catch { Write-Verbose "No session lock to release." }

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

    It 'seeds README.md for an optional folder that already exists on disk' {
        # Optional folders (e.g. ca-experiments/) are not created by step 50.
        # But if one exists on disk (manually created or pre-existing), step 50
        # must seed its README just like it does for required folders.
        $optPath = Join-Path $script:tmpWs 'ca-experiments'
        New-Item -ItemType Directory -Path $optPath -Force | Out-Null

        $result = Invoke-CABStep50 -Context $script:ctx
        $result.status | Should -Be 'ok'
        Test-Path (Join-Path $optPath 'README.md') | Should -BeTrue `
            -Because 'optional folder exists on disk — step 50 must seed its README'
    }

    It 'fails clearly when a regular file sits at the expected folder path' {
        # Pre-create a FILE (not a directory) at one of the required-folder paths.
        $collision = Join-Path $script:tmpWs 'ca-tools'
        Set-Content -Path $collision -Value 'I am a file, not a directory' -Encoding utf8

        $result = Invoke-CABStep50 -Context $script:ctx
        $result.status | Should -Be 'fail'
        $result.details | Should -Match 'not a directory'
    }

    It 'warns when a regular file sits at an optional-folder path but still returns ok' {
        # Pre-create a FILE (not a directory) at an optional-folder path.
        # The step must not fail (optional-folder collisions are non-fatal) but
        # must emit the "exists but is not a directory" warning introduced in
        # cycle-3 to match the required-folder behaviour from cycle-2.
        $collision = Join-Path $script:tmpWs 'ca-experiments'
        Set-Content -Path $collision -Value 'I am a file, not a directory' -Encoding utf8

        $allOutput = Invoke-CABStep50 -Context $script:ctx 6>&1

        # Status must still be ok — optional-folder collisions are non-fatal.
        $result = $allOutput | Where-Object { $_ -is [hashtable] }
        if (-not $result) {
            $result = $allOutput | Where-Object { $_.Keys -contains 'status' }
        }
        $result.status | Should -Be 'ok' -Because 'file-at-optional-folder-path must not fail the step'

        # The warning must have been emitted.
        $warnings = $allOutput |
            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
            Where-Object { $_.MessageData -match 'exists but is not a directory' }
        ($warnings | Measure-Object).Count | Should -BeGreaterOrEqual 1 `
            -Because 'a file-at-optional-folder-path must produce a visible warning'
    }

    It 'warns when a folder template is missing instead of silently skipping' {
        # Point RepoRoot at a temp dir that has no templates/folder-readmes/
        # so every template lookup misses, triggering the warning path.
        $emptyRepo = Join-Path ([System.IO.Path]::GetTempPath()) "cab-step50-empty-$(Get-Random)"
        New-Item -ItemType Directory -Path (Join-Path $emptyRepo 'manifest') -Force | Out-Null
        Copy-Item -Path (Join-Path $script:repoRoot 'manifest/folders.yaml') `
                  -Destination (Join-Path $emptyRepo 'manifest/folders.yaml')
        $script:ctx.RepoRoot = $emptyRepo

        # Capture Information stream (Write-Host → stream 6) alongside stdout.
        $allOutput = Invoke-CABStep50 -Context $script:ctx 6>&1

        # The result must still be ok (missing templates are non-fatal).
        $result = $allOutput | Where-Object { $_ -is [hashtable] }
        if (-not $result) {
            # When piped, the hashtable return value appears as a PSObject.
            $result = $allOutput | Where-Object { $_.Keys -contains 'status' }
        }
        $result.status | Should -Be 'ok' -Because 'missing templates must never fail the step'

        # At least one "No README template" warning must have been emitted.
        $warnings = $allOutput |
            Where-Object { $_ -is [System.Management.Automation.InformationRecord] } |
            Where-Object { $_.MessageData -match 'No README template' }
        ($warnings | Measure-Object).Count | Should -BeGreaterOrEqual 1 `
            -Because 'missing templates must produce a visible warning'

        Remove-Item -Recurse -Force $emptyRepo -ErrorAction SilentlyContinue
    }
}
