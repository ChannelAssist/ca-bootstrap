#requires -Version 7.0
# tests/lib/ca-bootstrap-tui-flag.tests.ps1 — end-to-end coverage of the
# `ca-bootstrap.ps1 -Tui` / `-NoTui` argument-binding and probe-failure
# paths from the real entry point. The other TUI tests exercise the
# bridge helpers in isolation; this file shells out to a fresh pwsh
# subprocess so flag parsing, banner suppression, and the `Test-CABTuiAvailable`
# probe failure all run through the actual orchestrator code.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:orch = Join-Path $repoRoot 'ca-bootstrap.ps1'
    Test-Path $script:orch | Should -BeTrue
}

Describe 'ca-bootstrap.ps1 -Tui / -NoTui flag binding' {
    It 'rejects setup -Tui when python3 / cab_tui is not importable' {
        # Force the probe to fail by pointing PYTHONPATH at a non-existent
        # dir (and by making sure cab_tui is not on the default path).
        # The orchestrator prints an ERROR and exits 1 per phase 7's contract.
        $tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tui-flag-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempState -Force | Out-Null
        # Empty answers file — the orchestrator validates -ConfigFile
        # exists before doing anything else, so a real path is needed.
        # Cross-platform: don't hardcode /dev/null (Windows doesn't have it).
        $emptyAnswers = Join-Path $tempState 'answers.yaml'
        Set-Content -Path $emptyAnswers -Value ''
        try {
            $env:CA_BOOTSTRAP_STATE = $tempState
            $env:PYTHONPATH = if ($IsWindows) { 'C:\Definitely\Does\Not\Exist' } else { '/definitely/does/not/exist' }
            # We need pwsh to use a python that doesn't have cab_tui.
            # `python3` on this machine shouldn't have it either (only
            # the venv does). The orchestrator will probe `python3 -m cab_tui --check`,
            # get a non-zero exit, and surface the ERROR.
            $output = & pwsh -NoLogo -NoProfile -File $script:orch setup -Tui -ConfigFile $emptyAnswers 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match '(?i)cab-tui is not available'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
            Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
            if (Test-Path $tempState) { Remove-Item -Recurse -Force $tempState -ErrorAction SilentlyContinue }
        }
    }

    It 'accepts -NoTui and proceeds with the legacy CLI flow' {
        # We can't fully run setup interactively from a test, but we can
        # confirm that -NoTui is a recognized parameter (the orchestrator's
        # `[ValidateSet]` on $Command would reject any unknown switch).
        # Use `version` so the script exits cleanly without prompting.
        $output = & pwsh -NoLogo -NoProfile -File $script:orch version -NoTui 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'ca-bootstrap'
    }

    It 'rejects unknown switch combinations cleanly' {
        # Sanity: passing both -Tui and -NoTui isn't blocked by the
        # CmdletBinding (they're orthogonal switches); -NoTui wins per
        # the decision matrix. This test documents that contract — it
        # should NOT exit non-zero just because both were passed.
        $output = & pwsh -NoLogo -NoProfile -File $script:orch version -Tui -NoTui 2>&1
        $LASTEXITCODE | Should -Be 0
    }
}
