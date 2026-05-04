#requires -Version 7.0
# tests/lib/journal.tests.ps1 — Pester tests for the action journal.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
}

Describe 'Journal round-trip' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-jtest-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        # The journal lib captured its $Script: paths at dot-source time;
        # ours don't reach it. Reset-CABJournalState re-reads the env var.
        Reset-CABJournalState
    }
    AfterEach {
        # Stop any active transcript so Windows releases the file handle
        # before we try to delete the temp dir. Linux/macOS allow deletion
        # of open files, but NTFS does not.
        try { Stop-Transcript | Out-Null } catch { }
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'writes a parseable journal on first save' {
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'
        Add-CABJournalEntry -Step '40-workspace' -Action 'create_folder' -Data @{ path = '/tmp/x' } | Out-Null
        Save-CABJournal

        $raw = Get-Content -Raw (Get-CABJournalPath)
        $raw | Should -Not -BeNullOrEmpty
        $parsed = ConvertFrom-Yaml $raw
        $parsed.schema_version | Should -Be 1
        @($parsed.sessions).Count | Should -Be 1
    }

    It 'accumulates sessions across saves' {
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'
        Add-CABJournalEntry -Step '50-folders' -Action 'create_folder' -Data @{ path = '/tmp/a' } | Out-Null
        Save-CABJournal
        try { Stop-Transcript | Out-Null } catch { }

        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'doctor' -Version '0.0.0-test'
        Save-CABJournal

        $parsed = ConvertFrom-Yaml (Get-Content -Raw (Get-CABJournalPath))
        @($parsed.sessions).Count | Should -Be 2
    }

    It 'filters Get-CABJournalEntries by Action and Step' {
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'
        Add-CABJournalEntry -Step '40-workspace' -Action 'create_folder' -Data @{ path = '/tmp/ws' } | Out-Null
        Add-CABJournalEntry -Step '60-repos'     -Action 'clone_repo'    -Data @{ path = '/tmp/r1' } | Out-Null
        Add-CABJournalEntry -Step '60-repos'     -Action 'clone_repo'    -Data @{ path = '/tmp/r2' } | Out-Null

        @(Get-CABJournalEntries -Action 'clone_repo').Count    | Should -Be 2
        @(Get-CABJournalEntries -Step   '40-workspace').Count  | Should -Be 1
        @(Get-CABJournalEntries -Action 'create_folder' -Step '40-workspace').Count | Should -Be 1
    }

    It 'Mark-CABEntryUndone updates the entry and excludes it from default queries' {
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'
        $e = Add-CABJournalEntry -Step '60-repos' -Action 'clone_repo' -Data @{ path = '/tmp/r' }

        Mark-CABEntryUndone -EntryId $e.id | Should -BeTrue

        @(Get-CABJournalEntries -Action 'clone_repo').Count                 | Should -Be 0
        @(Get-CABJournalEntries -Action 'clone_repo' -IncludeUndone).Count | Should -Be 1
    }
}
