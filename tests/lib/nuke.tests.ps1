#requires -Version 7.0
# tests/lib/nuke.tests.ps1
#
# Hermetic Pester coverage for scripts/nuke.sh. We never touch the real
# ~/.ca-bootstrap directory: every case sets CA_BOOTSTRAP_STATE to a temp
# path so the rm -rf step targets that instead. Bash + the script's
# DRY_RUN / CONFIRM env knobs let us assert the contract without
# uninstalling tools or unspooling the journal of the host machine.

BeforeAll {
    $script:repoRoot   = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:nukeScript = Join-Path $script:repoRoot 'scripts/nuke.sh'
    Test-Path $script:nukeScript | Should -BeTrue -Because 'scripts/nuke.sh must exist before testing it'
}

# scripts/nuke.sh is a bash script. On Windows runners it executes under
# Git Bash, which doesn't translate Windows-form paths (`C:\Users\...`)
# into POSIX form when they arrive via $env:VAR — they reach the script
# as-is, fail the `case "$STATE_DIR" in /*) ;; *) err ... ;;` "must be
# absolute" guard, and every test case under this Describe ends up
# asserting against the wrong error message. The user-facing flow
# (`make nuke` with $HOME or an explicitly-POSIX state dir) works on
# Windows because Git Bash + the Makefile recipe present POSIX paths;
# what doesn't work is round-tripping a Windows-form `[System.IO.Path]`
# value through PowerShell→bash→case-match. Skip the suite there
# rather than encode platform-specific path translation in every case.
Describe 'scripts/nuke.sh' -Skip:$IsWindows {
    BeforeEach {
        # Path must end in '.ca-bootstrap' so it satisfies the script's
        # safety guard (which refuses anything else, by design — see
        # "CA_BOOTSTRAP_STATE='...' does not end in '/.ca-bootstrap'").
        # We nest the dir under a unique random parent so concurrent
        # test runs don't collide.
        $script:tempParent = Join-Path ([System.IO.Path]::GetTempPath()) "cab-nuke-$(Get-Random)"
        $script:tempState  = Join-Path $script:tempParent '.ca-bootstrap'
        [void](New-Item -ItemType Directory -Path $script:tempState -Force)
        # Seed a real journal so undo doesn't hit "no reversible
        # actions" before we get a chance to assert anything. Empty
        # sessions list is enough to keep the script happy without
        # actually reversing on-disk state.
        Set-Content -Path (Join-Path $script:tempState 'journal.yaml') `
            -Value "schema_version: 1`nsessions: []`nhost: { os: macos, user: test, hostname: test }" `
            -Encoding utf8NoBOM
    }
    AfterEach {
        if ($script:tempParent -and (Test-Path $script:tempParent)) {
            Remove-Item -Recurse -Force $script:tempParent -ErrorAction SilentlyContinue
        }
    }

    It 'DRY_RUN=1 + CONFIRM=1 prints the plan and exits 0 without touching the state dir' {
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        $env:DRY_RUN = '1'
        $env:CONFIRM = '1'
        try {
            $output = & bash $script:nukeScript 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'DRY_RUN: nuke plan validated'
            Test-Path $script:tempState | Should -BeTrue -Because 'DRY_RUN must not delete anything'
            Test-Path (Join-Path $script:tempState 'journal.yaml') | Should -BeTrue
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
            Remove-Item Env:CONFIRM -ErrorAction SilentlyContinue
        }
    }

    It 'INCLUDE_TOOLS=1 surfaces the destructive-tools warning + adds -IncludeTools to undo' {
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        $env:DRY_RUN = '1'
        $env:CONFIRM = '1'
        $env:INCLUDE_TOOLS = '1'
        try {
            $output = & bash $script:nukeScript 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Uninstall manifest tools'
            $output | Should -Match 'WARNING'
            # We pass -IncludeTools (PascalCase, single dash) — PowerShell
            # rejects the hyphenated --include-tools form. PR #42 review
            # caught this regressing here; assertion is intentionally
            # specific so a future contributor who switches back to
            # hyphenated style sees a fast failure.
            $output | Should -Match '-IncludeTools'
            $output | Should -Not -Match '--include-tools'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
            Remove-Item Env:CONFIRM -ErrorAction SilentlyContinue
            Remove-Item Env:INCLUDE_TOOLS -ErrorAction SilentlyContinue
        }
    }

    It 'undo invocation does not trip the -Unattended-requires-ConfigFile error' {
        # PR #42 review caught a flag-binding regression: -Unattended
        # without -ConfigFile makes ca-bootstrap.ps1 exit 1 immediately
        # before any reversal happens. The "CONFIRM=1 actually removes
        # the state dir" test masked it because the rm -rf still ran.
        # Assert explicitly against the error string so a re-introduction
        # fails this test even if other behavior happens to look correct.
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        $env:CONFIRM = '1'
        try {
            $output = & bash $script:nukeScript 2>&1 | Out-String
            $output | Should -Not -Match '-Unattended requires -ConfigFile'
            $output | Should -Not -Match 'A parameter cannot be found that matches parameter name'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:CONFIRM -ErrorAction SilentlyContinue
        }
    }

    It 'refuses unsafe STATE_DIR paths' {
        # Each case must abort with exit 1 and NOT touch the filesystem.
        # We invoke via `bash -c` with explicit env-var assignment so
        # the test can pass a TRULY EMPTY CA_BOOTSTRAP_STATE through to
        # the script. Going through PowerShell's $env:CA_BOOTSTRAP_STATE
        # = '' would unset the variable instead, which makes the
        # script's "${CA_BOOTSTRAP_STATE-default}" fall back to
        # $HOME/.ca-bootstrap — i.e., nuke the user's REAL state
        # directory. (Yes, this happened during PR #42 development.
        # The script was hardened with `-` instead of `:-` so an
        # empty value stays empty, but we still need to reach it
        # without PowerShell laundering it into "unset".)
        $cases = @(
            @{ Path = ''        ; Match = 'CA_BOOTSTRAP_STATE is empty' }
            @{ Path = '/'       ; Match = 'refuse to nuke the root filesystem' }
            @{ Path = $HOME     ; Match = 'refuse to nuke the home directory' }
            @{ Path = '/tmp/not-a-state-dir' ; Match = "does not end in '.ca-bootstrap'" }
            @{ Path = 'relative/path/.ca-bootstrap' ; Match = 'is not absolute' }
            @{ Path = '/.ca-bootstrap' ; Match = 'too few path components' }
        )
        foreach ($case in $cases) {
            # Single-quoted heredoc so $foo inside the bash command stays
            # literal until bash sees it. The CA_BOOTSTRAP_STATE
            # assignment is in the same shell invocation, so it's
            # guaranteed to reach nuke.sh as the value the test wrote.
            $bashCmd = "CONFIRM=1 CA_BOOTSTRAP_STATE='$($case.Path -replace ""'"", ""'\\''"")' '$script:nukeScript'"
            $output = & bash -c $bashCmd 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1 -Because "STATE_DIR='$($case.Path)' must be refused. Output:`n$output"
            $output | Should -Match $case.Match
        }
    }

    It 'aborts with exit 1 when the user types anything other than YES at the prompt' {
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        try {
            # Pipe "no" to stdin. The script falls back to stdin when
            # /dev/tty is unusable in this test sandbox.
            $output = 'no' | & bash $script:nukeScript 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $output | Should -Match 'Aborted'
            Test-Path $script:tempState | Should -BeTrue -Because 'an aborted nuke must not delete anything'
            Test-Path (Join-Path $script:tempState 'journal.yaml') | Should -BeTrue
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        }
    }

    It 'CONFIRM=1 actually removes the state dir' {
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        $env:CONFIRM = '1'
        try {
            # We expect the inner ca-bootstrap.ps1 undo call to fail or
            # noop (the temp dir has no real journal), but the script
            # advertises that it continues to the rm -rf regardless.
            $output = & bash $script:nukeScript 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "nuke completes even if undo finds nothing to undo. Output:`n$output"
            $output | Should -Match 'ca-bootstrap nuke complete'
            Test-Path $script:tempState | Should -BeFalse -Because 'CONFIRM=1 must remove the state dir'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:CONFIRM -ErrorAction SilentlyContinue
        }
    }

    It 'is idempotent: a second CONFIRM=1 invocation against an already-clean state succeeds' {
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        $env:CONFIRM = '1'
        try {
            & bash $script:nukeScript 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
            Test-Path $script:tempState | Should -BeFalse

            # Second run: nothing left to remove. Must still succeed
            # rather than fail because the state dir is missing.
            $output = & bash $script:nukeScript 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because "second nuke must be a clean no-op. Output:`n$output"
            $output | Should -Match 'already clean|nuke complete'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:CONFIRM -ErrorAction SilentlyContinue
        }
    }
}
