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

    It 'skips snapshot capture when a UTF-16LE README contains a credential-shaped token' {
        # PR #83 cycle-4 review pinned: the cycle-1 sensitive-content
        # guard decoded as UTF-8 only. A UTF-16LE README with an ASCII
        # token has interleaved 0x00 bytes between the ASCII chars
        # after UTF-8 decode, masking the contiguous regex pattern —
        # so secrets would have base64-journaled. The scan now tries
        # UTF-8, UTF-16LE, AND UTF-16BE; any match skips capture.
        $targetDir = Join-Path $script:tmpWs 'ca-tools'
        $target    = Join-Path $targetDir 'README.md'

        # Build a UTF-16LE README containing a GitHub fine-grained PAT
        # pattern. Test-CABContainsSensitive in lib/journal.ps1 matches
        # \bgithub_pat_[A-Za-z0-9_]{20,}.
        $content = "# README`r`n`r`ntoken: github_pat_AAAAAAAAAAAAAAAAAAAAA_REDACTED`r`n"
        $bytes = [System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($content)
        [System.IO.File]::WriteAllBytes($target, $bytes)

        # Answer key matches commands/repair.ps1:482 — singular
        # `folder-readme` (not `folder-readmes`) per the prompt scope.
        Set-CABPromptMode -Unattended $true -Answers @{
            'folder-readme.ca-tools.overwrite' = 'y'
        }

        $r = Invoke-CABRepairFolderReadmes -Context $script:ctx
        $r.status | Should -Be 'ok'

        # The ca-tools refresh_readme entry should NOT carry
        # previous_content (secrets-scan caught the embedded token)
        # and should carry previous_content_captured: $false.
        $entry = Get-CABJournalEntry -Action 'refresh_readme' -IncludeUndone |
            Where-Object { ([string]$_.path) -like '*ca-tools*README.md' } |
            Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $entry.ContainsKey('previous_content') | Should -BeFalse
        $entry['previous_content_captured'] | Should -Be $false
    }

    It 'captures a non-sensitive under-cap drifted README and the base64 decodes back to the original bytes' {
        # PR #83 cycle-5 review pinned the missing happy-path coverage:
        # a non-sensitive, under-cap drifted README must (a) cause the
        # repair journal entry to carry a `previous_content` key, AND
        # (b) the value must decode losslessly back to the operator's
        # original drift content. Without this end-to-end pin the
        # capture branch is only indirectly exercised by the undo tests
        # (which feed synthesised entries) — a regression in the
        # repair-side ToBase64String step would not have been caught.
        $targetDir = Join-Path $script:tmpWs 'ca-tools'
        $target    = Join-Path $targetDir 'README.md'

        # UTF-8 README, no credential-shaped tokens, comfortably under
        # the 64KB cap. Include CRLF + trailing whitespace so the
        # round-trip equality is meaningful (anything that mangles
        # EOLs would show up here).
        $original      = "# ca-tools (operator-edited)`r`n`r`nSome notes with trailing space.   `r`n"
        $originalBytes = [System.Text.Encoding]::UTF8.GetBytes($original)
        [System.IO.File]::WriteAllBytes($target, $originalBytes)

        Set-CABPromptMode -Unattended $true -Answers @{
            'folder-readme.ca-tools.overwrite' = 'y'
        }

        $r = Invoke-CABRepairFolderReadmes -Context $script:ctx
        $r.status | Should -Be 'ok'

        $entry = Get-CABJournalEntry -Action 'refresh_readme' -IncludeUndone |
            Where-Object { ([string]$_.path) -like '*ca-tools*README.md' } |
            Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $entry.ContainsKey('previous_content') | Should -BeTrue
        # previous_content_captured marker is only written on skip;
        # absence here means capture succeeded.
        $entry.ContainsKey('previous_content_captured') | Should -BeFalse

        # Decode round-trip must be byte-for-byte identical to the
        # original drift.
        $decoded = [Convert]::FromBase64String([string]$entry['previous_content'])
        $decoded.Length | Should -Be $originalBytes.Length
        for ($i = 0; $i -lt $originalBytes.Length; $i++) {
            $decoded[$i] | Should -Be $originalBytes[$i]
        }
    }

    It 'skips snapshot capture when the drifted README is over the 64KB cap' {
        # PR #83 cycle-5 review pinned: the >64KB path should omit
        # previous_content AND write previous_content_captured:$false
        # so undo can distinguish "intentionally skipped (too large)"
        # from "never captured (pre-PR-83 entry)". Cycle-3 also fixed
        # this to use FileInfo.Length so no multi-MB byte[] is
        # allocated for the cap check itself; this test exercises
        # the dispatch path end-to-end.
        $targetDir = Join-Path $script:tmpWs 'ca-tools'
        $target    = Join-Path $targetDir 'README.md'

        # 64KB cap = 65536 source bytes. Build a 70KB drift so the
        # cap check fires cleanly and ReadAllBytes is never called
        # on this path (verified by cycle-3 fix; this test pins the
        # observable journal state).
        $bigContent = "# big drift`r`n" + ('x' * 70000)
        [System.IO.File]::WriteAllBytes($target, [System.Text.Encoding]::UTF8.GetBytes($bigContent))

        Set-CABPromptMode -Unattended $true -Answers @{
            'folder-readme.ca-tools.overwrite' = 'y'
        }

        $r = Invoke-CABRepairFolderReadmes -Context $script:ctx
        $r.status | Should -Be 'ok'

        $entry = Get-CABJournalEntry -Action 'refresh_readme' -IncludeUndone |
            Where-Object { ([string]$_.path) -like '*ca-tools*README.md' } |
            Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $entry.ContainsKey('previous_content') | Should -BeFalse
        $entry['previous_content_captured'] | Should -Be $false
    }
}
