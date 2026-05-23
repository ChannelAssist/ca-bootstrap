#requires -Version 7.0
# tests/lib/journal-session-required.tests.ps1
#
# Audit for issue: ensure every production code path that calls
# Add-CABJournalEntry is paired with Start-CABSession upstream.
#
# Two layers of defence:
#   1. Runtime contract — Add-CABJournalEntry throws when no session
#      is active. A silent $null return would create invisible
#      audit-trail gaps.
#   2. Static audit — every production .ps1 that calls
#      Add-CABJournalEntry must be reachable from a command branch in
#      ca-bootstrap.ps1 that calls Start-CABSession (or via Repair-
#      CABJournal, which constructs a synthetic session).

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
}

Describe 'Add-CABJournalEntry refuses to write without an active session' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-jsess-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "No active transcript to stop." }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
    }

    It 'throws "No active session" when no session has been started' {
        # No Read-CABJournal, no Start-CABSession — this models a
        # production code path that forgot to pair Add-CABJournalEntry
        # with Start-CABSession somewhere upstream.
        { Add-CABJournalEntry -Step '99-test' -Action 'pretend' -Data @{ foo = 'bar' } } |
            Should -Throw -ExpectedMessage '*No active session*'
    }

    It 'throws when the journal has been read but no session started' {
        # Read-CABJournal loads $Script:CABJournalState but does NOT
        # create a session — Add-CABJournalEntry must still refuse.
        Read-CABJournal | Out-Null
        { Add-CABJournalEntry -Step '99-test' -Action 'pretend' -Data @{ foo = 'bar' } } |
            Should -Throw -ExpectedMessage '*No active session*'
    }

    It 'throws when the journal already contains prior sessions but none was started this run' {
        # Production case (caught by PR #80 review): a real journal almost
        # always has prior sessions on disk. If Get-CABCurrentSession
        # returned sessions[-1] unconditionally, Add-CABJournalEntry would
        # silently append to the most-recent prior session instead of
        # throwing — defeating the entire "session-required" contract.
        # This test pins the corrected behavior: only the session that
        # Start-CABSession created in THIS process run counts as active.
        Initialize-CABJournal
        $priorJournal = @'
schema_version: 1
host:
  os: linux
  user: ci
  hostname: prior-run
sessions:
  - id: 2026-01-01T00:00:00Z
    command: setup
    ca_bootstrap_version: 0.0.0-prior
    actions:
      - id: 2026-01-01T00:00:00Z-1
        step: '00-prior'
        action: pretend
        data: {}
'@
        Set-Content -Path (Join-Path $script:tempState 'journal.yaml') -Value $priorJournal -Encoding utf8NoBOM
        Read-CABJournal | Out-Null
        # Sanity: the prior session loaded.
        @($Script:CABJournalState.sessions).Count | Should -BeGreaterOrEqual 1
        { Add-CABJournalEntry -Step '99-test' -Action 'pretend' -Data @{ foo = 'bar' } } |
            Should -Throw -ExpectedMessage '*No active session*'
    }

    It 'does NOT silently return $null (which would mask audit gaps)' {
        # Regression guard: if a future change ever softens the contract
        # back to "silently return $null", this assertion fails so the
        # softening is a conscious, reviewed decision (see PR
        # ChannelAssist/ca-bootstrap#74 cycle 22 review).
        $threw = $false
        try { Add-CABJournalEntry -Step '99-test' -Action 'pretend' | Out-Null }
        catch { $threw = $true }
        $threw | Should -BeTrue -Because 'silent $null returns hide missing-session bugs in production'
    }
}

Describe 'Orchestrator pairs Start-CABSession with every journal-mutating command' {
    BeforeAll {
        $script:orchestrator = Get-Content -Raw (Join-Path $script:repoRoot 'ca-bootstrap.ps1')
    }

    It 'only the read-only commands (doctor, manifest-drift) are allowed to skip Start-CABSession' {
        # The orchestrator computes $skipSession from $readOnlyCommand;
        # this test pins that list so a future contributor can't
        # accidentally widen the skip set to setup/repair/undo/manifest-edit.
        $script:orchestrator | Should -Match "\`$readOnlyCommand\s*=\s*\`$Command\s+-in\s+@\('doctor','manifest-drift'\)"
        $script:orchestrator | Should -Match "\`$skipSession\s*=\s*\`$silent\s+-and\s+\`$readOnlyCommand"
    }

    It 'every dispatched command runs Start-CABSession (or is explicitly read-only)' {
        # Parse the orchestrator's ValidateSet to discover the canonical
        # list of dispatched commands, then assert each one is either
        # in the read-only set or reaches Start-CABSession via the
        # non-skip branch (which all commands share).
        $validateMatch = [regex]::Match($script:orchestrator, "ValidateSet\(([^)]+)\)")
        $validateMatch.Success | Should -BeTrue
        $commands = $validateMatch.Groups[1].Value -split ',' |
            ForEach-Object { $_.Trim().Trim("'") } |
            Where-Object { $_ -notin @('help','--help','-h','version','--version') }

        $readOnly = @('doctor','manifest-drift')
        $journalMutating = $commands | Where-Object { $_ -notin $readOnly }

        # The mutating commands must include the entry points called
        # out in the audit: setup, repair, undo, manifest-edit.
        foreach ($expected in 'setup','repair','undo','manifest-edit') {
            $journalMutating | Should -Contain $expected
        }

        # And the non-skip branch must call Start-CABSession exactly
        # once with the command name — proving the pairing exists for
        # every mutating command (which all flow through that branch).
        $script:orchestrator | Should -Match 'Start-CABSession\s+-Command\s+\$Command'
    }
}

Describe 'Static audit: every production caller of Add-CABJournalEntry is reachable from a Start-CABSession' {
    It 'enumerates production callers and verifies each is dispatched via a session-starting command' {
        # Build the set of production files that call Add-CABJournalEntry.
        $productionDirs = @('commands','steps','lib') |
            ForEach-Object { Join-Path $script:repoRoot $_ }
        $callers = Get-ChildItem -Path $productionDirs -Filter '*.ps1' -Recurse |
            Where-Object {
                # Path-separator-agnostic filter: the lib/journal.ps1
                # definition site itself contains the function name and
                # must be excluded. Normalize to forward slashes first
                # so the same pattern works on Linux and Windows runners
                # (Windows $_.FullName uses backslash; `-like '*lib/journal.ps1*'`
                # would silently fail to match `D:\...\lib\journal.ps1`).
                $relForwardSlash = $_.FullName.Replace('\','/')
                (Select-String -Path $_.FullName -Pattern '\bAdd-CABJournalEntry\b' -SimpleMatch:$false -Quiet) -and
                $relForwardSlash -notlike '*lib/journal.ps1'
            } |
            ForEach-Object { $_.FullName.Substring($script:repoRoot.Length + 1).Replace('\','/') }

        # Snapshot of the audit at the time this test was written.
        # New entries are welcome; each one must be reachable from a
        # command that calls Start-CABSession upstream. Update this
        # list deliberately when adding a new journaling step.
        $expected = @(
            'commands/repair.ps1',
            'lib/folder-readmes.ps1',
            'steps/20-prereqs.ps1',
            'steps/30-gh-auth.ps1',
            'steps/40-workspace.ps1',
            'steps/50-folders.ps1',
            'steps/60-repos.ps1',
            'steps/70-git-identity.ps1',
            'steps/80-extras.ps1'
        )
        ($callers | Sort-Object) | Should -Be ($expected | Sort-Object) -Because @"
A new production file calls Add-CABJournalEntry. Verify that every
command that loads it ALSO calls Start-CABSession upstream, then
add it to the expected list in
tests/lib/journal-session-required.tests.ps1.
"@

        # Every caller above must be reachable from setup or repair —
        # the two journal-mutating commands. Both call Start-CABSession
        # via the orchestrator's non-skip branch. setup discovers steps
        # via Get-CABSetupStepDef; repair dot-sources them by literal
        # path in its switch.
        $setup  = Get-Content -Raw (Join-Path $script:repoRoot 'commands/setup.ps1')
        $repair = Get-Content -Raw (Join-Path $script:repoRoot 'commands/repair.ps1')
        # Production steps that already prove reachable; they form the
        # "trusted transitive set" for lib/ helpers dot-sourced by a step.
        $reachableSteps = $callers | Where-Object { $_ -like 'steps/*' }
        $stepContent = @{}
        foreach ($s in $reachableSteps) {
            $stepContent[$s] = Get-Content -Raw (Join-Path $script:repoRoot $s)
        }
        foreach ($file in $callers) {
            if ($file -eq 'commands/repair.ps1') { continue }   # entry point itself
            $base = [System.IO.Path]::GetFileNameWithoutExtension($file)   # e.g. 20-prereqs
            $reachable =
                ($setup  -match [regex]::Escape("id = '$base'")) -or
                ($setup  -match [regex]::Escape($file))          -or
                ($repair -match [regex]::Escape($file))
            # lib/ helpers don't appear in setup's step discovery or
            # repair's switch by literal path. They are reached
            # transitively via a step that dot-sources them. Accept
            # that linkage as long as the dot-sourcing step is itself
            # in $callers (so its own session pairing is already
            # verified above).
            if (-not $reachable -and $file -like 'lib/*') {
                $leaf = [System.IO.Path]::GetFileName($file)   # e.g. folder-readmes.ps1
                foreach ($stepBody in $stepContent.Values) {
                    if ($stepBody -match [regex]::Escape($leaf)) { $reachable = $true; break }
                }
            }
            $reachable | Should -BeTrue -Because "$file must be reachable from setup or repair so Start-CABSession is paired upstream"
        }
    }
}
