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
        # PR #80 contract: Add-CABJournalEntry now throws without an
        # active session. Repair journals seed_readme actions, so we
        # must start a session paired with the Reset.
        Start-CABSession -Command 'repair' -Version '0.0.0-test' | Out-Null
        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
        foreach ($p in 'ca-tools','ca-docs','ca-platform','cm-product','ca-training','ca-work-dirs') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $p) -Force | Out-Null
        }
        $script:ctx = @{ RepoRoot = $script:repoRoot; WorkspacePath = $script:tmpWs }
        # Reset prompt mode to interactive before each test. Tests that need
        # scripted answers call Set-CABPromptMode themselves — the function
        # under test no longer forces unattended mode.
        Set-CABPromptMode -Unattended $false -Answers @{}
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        try { Unlock-CABSession } catch {}
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        Set-CABPromptMode -Unattended $false -Answers @{}
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
        # Test harness sets prompt mode — the function under test must NOT
        # force unattended mode; interactive runs must get a real prompt.
        Set-CABPromptMode -Unattended $true -Answers @{ 'folder-readme.ca-tools.overwrite' = 'n' }

        Invoke-CABRepairFolderReadmes -Context $script:ctx | Out-Null
        (Get-Content -Raw $drift) | Should -Match 'my edits'
    }

    # ---------------------------------------------------------------------------
    # Failure-path tests — Copy-Item error propagation
    # ---------------------------------------------------------------------------

    It 'returns status=fail when Copy-Item cannot write the seeded README (destination directory is read-only)' {
        # Make the ca-tools folder read-only so Copy-Item into it fails.
        # This is reliable on macOS/Linux (chmod a-w). On Windows, ACLs are
        # more complex; we skip if the chmod equivalent doesn't block writes.
        $targetDir = Join-Path $script:tmpWs 'ca-tools'

        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'Read-only directory injection unreliable on Windows without ACL manipulation; failure path verified by code review'
            return
        }

        # Remove write permission from the folder so Copy-Item into it fails.
        & chmod a-w $targetDir
        try {
            $r = Invoke-CABRepairFolderReadmes -Context $script:ctx
            $r.status | Should -Be 'fail'
            $r.details | Should -Match 'Failed to seed README'
        } finally {
            # Always restore write permission so AfterEach cleanup can remove the dir.
            & chmod u+w $targetDir
        }
    }

    It 'returns status=fail when Copy-Item cannot overwrite a drifted README (failure injection deferred)' {
        # Failure injection for the overwrite Copy-Item path is not reliably
        # cross-platform:
        #   - chmod a-w on the parent directory: on macOS, overwriting an
        #     *existing* file does not require write permission on the parent
        #     (the inode is already allocated), so Copy-Item -Force succeeds.
        #   - chmod a-w / chflags uchg on the file itself: Copy-Item -Force
        #     bypasses the read-only bit when the caller is the file owner.
        #   - Making the destination path a directory: would hit a different
        #     error code than the one we're testing for.
        # The try/catch wrapping and the "Failed to overwrite README" message
        # are verified by code review; manual testing on a filesystem mounted
        # read-only (e.g. a read-only bind mount) confirms the path.
        # Failure path tested manually; cross-platform test injection deferred.
        Set-ItResult -Skipped -Because 'Cross-platform Copy-Item overwrite failure injection deferred; try/catch verified by code review (see comment in test file)'
    }
}
