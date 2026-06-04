#requires -Version 7.0
# tests/lib/folder-readmes-helper.tests.ps1 — regression tests for
# Invoke-CABSeedFolderReadme -PathType Leaf guards (cycle-23, PR #74).

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/folder-readmes.ps1')
}

Describe 'Invoke-CABSeedFolderReadme — file-type collision handling' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cab-seed-helper-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-seed-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState
        # Pair Reset-CABJournalState with Start-CABSession so the
        # journal contract (PR #80) holds: Add-CABJournalEntry now
        # throws "No active session" if a session wasn't started this
        # process run. Invoke-CABSeedFolderReadme journals a
        # 'seed_readme' action on success, so a session is required.
        Start-CABSession -Command 'repair' -Version '0.0.0-test' | Out-Null
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'templates/folder-readmes/test-folder') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'workspace/test-folder') -Force | Out-Null
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        try { Unlock-CABSession } catch {}
        foreach ($p in @($script:tmp, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It "returns 'no-template' when the template README.md path is a directory (not a file)" {
        # Template path exists as a directory — not a file
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'templates/folder-readmes/test-folder/README.md') -Force | Out-Null
        $result = Invoke-CABSeedFolderReadme `
            -RepoRoot $script:tmp `
            -WorkspacePath (Join-Path $script:tmp 'workspace') `
            -FolderPath 'test-folder' `
            -StepName 'test'
        $result | Should -Be 'no-template'
    }

    It "returns 'no-template' when the template is missing entirely" {
        # No README.md at template path at all
        $result = Invoke-CABSeedFolderReadme `
            -RepoRoot $script:tmp `
            -WorkspacePath (Join-Path $script:tmp 'workspace') `
            -FolderPath 'test-folder' `
            -StepName 'test'
        $result | Should -Be 'no-template'
    }

    It "returns 'failed' when the target path exists as a directory and preserves it" {
        $templateFile = Join-Path $script:tmp 'templates/folder-readmes/test-folder/README.md'
        Set-Content -Path $templateFile -Value '# template' -Encoding utf8

        # Target path exists as a directory instead of a file
        New-Item -ItemType Directory -Path (Join-Path $script:tmp 'workspace/test-folder/README.md') -Force | Out-Null

        $result = Invoke-CABSeedFolderReadme `
            -RepoRoot $script:tmp `
            -WorkspacePath (Join-Path $script:tmp 'workspace') `
            -FolderPath 'test-folder' `
            -StepName 'test'
        $result | Should -Be 'failed'
        # Verify the directory was preserved (not clobbered)
        (Test-Path (Join-Path $script:tmp 'workspace/test-folder/README.md') -PathType Container) | Should -BeTrue
    }

    It "returns 'seeded' and copies the template when both paths are clean" {
        $templateFile = Join-Path $script:tmp 'templates/folder-readmes/test-folder/README.md'
        Set-Content -Path $templateFile -Value '# template content' -Encoding utf8

        $result = Invoke-CABSeedFolderReadme `
            -RepoRoot $script:tmp `
            -WorkspacePath (Join-Path $script:tmp 'workspace') `
            -FolderPath 'test-folder' `
            -StepName 'test'
        $result | Should -Be 'seeded'
        (Test-Path (Join-Path $script:tmp 'workspace/test-folder/README.md') -PathType Leaf) | Should -BeTrue
    }

    It "returns 'kept' when the target already exists as a file (idempotent)" {
        $templateFile = Join-Path $script:tmp 'templates/folder-readmes/test-folder/README.md'
        Set-Content -Path $templateFile -Value '# template content' -Encoding utf8
        $targetFile = Join-Path $script:tmp 'workspace/test-folder/README.md'
        Set-Content -Path $targetFile -Value '# my existing content' -Encoding utf8

        $result = Invoke-CABSeedFolderReadme `
            -RepoRoot $script:tmp `
            -WorkspacePath (Join-Path $script:tmp 'workspace') `
            -FolderPath 'test-folder' `
            -StepName 'test'
        $result | Should -Be 'kept'
        # Verify existing content was not overwritten
        (Get-Content -Raw $targetFile) | Should -Match 'my existing content'
    }
}
