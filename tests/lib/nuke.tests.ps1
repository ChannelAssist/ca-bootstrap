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

Describe 'scripts/nuke.sh' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-nuke-$(Get-Random).d"
        [void](New-Item -ItemType Directory -Path $script:tempState -Force)
        # Drop a marker file so the rm -rf step actually has something
        # to remove. Without it the script's "already clean" branch would
        # short-circuit and we couldn't assert the deletion happened.
        Set-Content -Path (Join-Path $script:tempState 'journal.yaml') -Value 'schema_version: 1' -Encoding utf8NoBOM
    }
    AfterEach {
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
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

    It 'INCLUDE_TOOLS=1 surfaces the destructive-tools warning + adds --include-tools to undo' {
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        $env:DRY_RUN = '1'
        $env:CONFIRM = '1'
        $env:INCLUDE_TOOLS = '1'
        try {
            $output = & bash $script:nukeScript 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0
            $output | Should -Match 'Uninstall manifest tools'
            $output | Should -Match 'WARNING'
            $output | Should -Match '--include-tools'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:DRY_RUN -ErrorAction SilentlyContinue
            Remove-Item Env:CONFIRM -ErrorAction SilentlyContinue
            Remove-Item Env:INCLUDE_TOOLS -ErrorAction SilentlyContinue
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
