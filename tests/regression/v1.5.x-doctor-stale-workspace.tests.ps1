#requires -Version 7.0
# tests/regression/v1.5.x-doctor-stale-workspace.tests.ps1
#
# Bug fixed in this branch: doctor reported a stale workspace path after
# the user re-ran setup against an existing folder. Step 40-workspace
# only emitted a `create_folder` journal entry when it actually mkdir'd
# the directory — when the workspace already existed it returned status
# 'skip' and wrote nothing, so doctor's "find the most-recent
# 40-workspace create_folder" lookup surfaced the previous run's path.
#
# Fix: step 40 now also emits a `select_workspace` action on every run,
# regardless of whether the folder was created. Doctor reads
# select_workspace first, falls back to the legacy create_folder filter.
#
# This regression test exercises both the new path and the legacy
# fallback so a future contributor who removes either one will see a
# clear failure at the journal/lookup layer.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')

    # Replicates the workspace-resolution block in commands/doctor.ps1
    # (the Get-CABJournalEntry calls only — not the env-var/default
    # fallback). If doctor.ps1 changes its read order, update this too.
    # Defined at script scope (not inside a Describe) so Pester v5's
    # script-block isolation doesn't hide it from It blocks.
    function Resolve-CABDoctorWorkspaceFromJournal {
        $entries = @(Get-CABJournalEntry -Action 'select_workspace' -Step '40-workspace')
        if ($entries.Count -eq 0) {
            $entries = @(Get-CABJournalEntry -Action 'create_folder' -Step '40-workspace' |
                Where-Object { $_.is_workspace_root })
        }
        if ($entries.Count -eq 0) { return $null }
        return [string]$entries[-1].path
    }

    # Start-CABSession holds a per-state-dir lock for non-doctor commands
    # and Reset-CABJournalState doesn't drop it (the lock dir on disk is
    # the source of truth, not in-memory state). Tests that simulate
    # multiple setup runs against the same state must release the lock
    # explicitly between sessions.
    function Reset-CABTestSession {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "No active transcript to stop." }
        Unlock-CABSession
        Reset-CABJournalState
        Read-CABJournal | Out-Null
    }
}

Describe 'doctor — workspace resolution from journal (regression v1.5.x)' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-doc-ws-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState
        Read-CABJournal | Out-Null
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "No active transcript to stop." }
        Unlock-CABSession
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'picks the most-recent select_workspace path even when an older create_folder exists for a different path' {
        # Session 1: an older setup that *created* workspace A. Emits
        # both the legacy create_folder (because mkdir actually ran) and
        # the new select_workspace.
        Start-CABSession -Command 'setup' -Version '1.4.0-test'
        Add-CABJournalEntry -Step '40-workspace' -Action 'create_folder' `
            -Data @{ path = '/tmp/ws-A'; is_workspace_root = $true } | Out-Null
        Add-CABJournalEntry -Step '40-workspace' -Action 'select_workspace' -Reversible $false `
            -Data @{ path = '/tmp/ws-A'; is_workspace_root = $true; created = $true } | Out-Null
        Save-CABJournal

        # Session 2: the user reruns setup with existing path B. Only
        # select_workspace is emitted (no create_folder, since mkdir
        # didn't run). Pre-fix this would leave session 1's
        # create_folder as the only workspace-root marker, and doctor
        # would report path A — the stale one.
        Reset-CABTestSession
        Start-CABSession -Command 'setup' -Version '1.5.0-test'
        Add-CABJournalEntry -Step '40-workspace' -Action 'select_workspace' -Reversible $false `
            -Data @{ path = '/tmp/ws-B'; is_workspace_root = $true; created = $false } | Out-Null
        Save-CABJournal

        Reset-CABTestSession
        Resolve-CABDoctorWorkspaceFromJournal | Should -Be '/tmp/ws-B' `
            -Because 'doctor must reflect the workspace the most recent setup chose, not the older mkdir record.'
    }

    It 'falls back to the legacy create_folder filter when the journal has no select_workspace entries' {
        # Pre-fix journals only have create_folder. The fallback keeps
        # doctor working for users on old journal files until the next
        # setup run rewrites a select_workspace entry.
        Start-CABSession -Command 'setup' -Version '1.4.0-test'
        Add-CABJournalEntry -Step '40-workspace' -Action 'create_folder' `
            -Data @{ path = '/tmp/legacy-ws'; is_workspace_root = $true } | Out-Null
        Save-CABJournal

        Reset-CABTestSession
        Resolve-CABDoctorWorkspaceFromJournal | Should -Be '/tmp/legacy-ws'
    }

    It 'returns $null when no workspace selection has ever been recorded' {
        Resolve-CABDoctorWorkspaceFromJournal | Should -BeNullOrEmpty
    }

    It 'ignores undone select_workspace entries' {
        # Two sessions so the entry IDs (whole-second timestamps) don't
        # collide — Set-CABEntryUndone matches by id and would mark
        # both entries as undone if they shared a timestamp.
        Start-CABSession -Command 'setup' -Version '1.5.0-test'
        $stale = Add-CABJournalEntry -Step '40-workspace' -Action 'select_workspace' -Reversible $false `
            -Data @{ path = '/tmp/ws-stale'; is_workspace_root = $true; created = $true }
        Save-CABJournal
        Reset-CABTestSession

        Start-Sleep -Seconds 1
        Start-CABSession -Command 'setup' -Version '1.5.0-test'
        Add-CABJournalEntry -Step '40-workspace' -Action 'select_workspace' -Reversible $false `
            -Data @{ path = '/tmp/ws-live'; is_workspace_root = $true; created = $false } | Out-Null
        Set-CABEntryUndone -EntryId $stale.id | Out-Null
        Save-CABJournal

        Reset-CABTestSession
        Resolve-CABDoctorWorkspaceFromJournal | Should -Be '/tmp/ws-live'
    }
}

Describe 'Step 40 — emits select_workspace on every run (regression v1.5.x)' {
    BeforeAll {
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        . (Join-Path $repoRoot 'lib/prompts.ps1')
        . (Join-Path $repoRoot 'steps/40-workspace.ps1')
    }
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-step40-$(Get-Random)"
        $script:tempWs    = Join-Path ([System.IO.Path]::GetTempPath()) "cab-step40-ws-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE     = $script:tempState
        $env:CA_BOOTSTRAP_WORKSPACE = $script:tempWs
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '1.5.0-test'
        Set-CABPromptMode -Unattended $true -Answers @{ 'workspace.use_default' = $true }
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "No active transcript to stop." }
        Unlock-CABSession
        Set-CABPromptMode -Unattended $false -Answers @{}
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
        if ($script:tempWs -and (Test-Path $script:tempWs)) {
            Remove-Item -Recurse -Force $script:tempWs -ErrorAction SilentlyContinue
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE     -ErrorAction SilentlyContinue
        Remove-Item Env:CA_BOOTSTRAP_WORKSPACE -ErrorAction SilentlyContinue
    }

    It 'emits select_workspace AND create_folder when the workspace folder is newly created' {
        $r = Invoke-CABStep40 -Context @{ TotalSteps = 8 }
        $r.status | Should -Be 'ok'

        $sel = @(Get-CABJournalEntry -Action 'select_workspace' -Step '40-workspace')
        $crt = @(Get-CABJournalEntry -Action 'create_folder'    -Step '40-workspace' |
                 Where-Object { $_.is_workspace_root })
        $sel.Count | Should -Be 1
        $sel[0].path | Should -Be $script:tempWs
        $sel[0].created | Should -BeTrue
        $crt.Count | Should -Be 1
        $crt[0].path | Should -Be $script:tempWs
    }

    It 'emits select_workspace but NOT create_folder when the workspace already existed (the bug case)' {
        # Pre-create the workspace so step 40 takes the skip path. This
        # is the exact scenario where the bug manifested: re-running
        # setup against an existing folder used to leave no journal
        # marker for the choice, so doctor surfaced an older path.
        [void](New-Item -ItemType Directory -Path $script:tempWs -Force)

        $r = Invoke-CABStep40 -Context @{ TotalSteps = 8 }
        $r.status | Should -Be 'skip'

        $sel = @(Get-CABJournalEntry -Action 'select_workspace' -Step '40-workspace')
        $crt = @(Get-CABJournalEntry -Action 'create_folder'    -Step '40-workspace' |
                 Where-Object { $_.is_workspace_root })
        $sel.Count | Should -Be 1 -Because 'select_workspace must be emitted on EVERY run, including skip.'
        $sel[0].path | Should -Be $script:tempWs
        $sel[0].created | Should -BeFalse
        $crt.Count | Should -Be 0 -Because 'create_folder must only be emitted when 40-workspace actually mkdirs.'
    }
}
