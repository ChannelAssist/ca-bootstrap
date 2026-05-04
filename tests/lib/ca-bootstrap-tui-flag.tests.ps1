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
    It 'rejects setup -Tui when python / cab_tui is not importable' {
        # We can't simply set PYTHONPATH to garbage: Test-CABTuiAvailable
        # PREPENDS the repo's cab-tui/ to PYTHONPATH (via _CABTuiPythonPath)
        # so a hostile PYTHONPATH would still resolve cab_tui from source.
        # The deterministic way to fail the probe is to put a python
        # shim earlier on PATH that exits non-zero on `-m cab_tui --check`.
        $tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tui-flag-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempState -Force | Out-Null
        $shimDir = Join-Path $tempState 'shim'
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        if ($IsWindows) {
            # Windows: a .cmd that always exits 99 stands in for the
            # python.exe / py.exe / python3.exe Find-CABPython tries.
            foreach ($name in 'python.exe','py.exe','python3.exe') {
                # On Windows, .exe matches a real PE. We can't easily forge
                # one, so use a .cmd of the same stem; cmd.exe resolves
                # `python` to python.cmd ahead of python.exe when the
                # PATHEXT order has .CMD first (which it does by default).
                Set-Content -Path (Join-Path $shimDir ($name -replace '\.exe$','.cmd')) -Value '@echo off`r`nexit /b 99'
            }
        } else {
            foreach ($name in 'python3','python') {
                $shim = Join-Path $shimDir $name
                Set-Content -Path $shim -Value "#!/bin/sh`nexit 99`n"
                & chmod +x $shim
            }
        }
        $sep = if ($IsWindows) { ';' } else { ':' }
        $origPath = $env:PATH
        try {
            $env:CA_BOOTSTRAP_STATE = $tempState
            # Prepend the shim dir so the bridge probe finds OUR python
            # before the real one. Test-CABTuiAvailable's `-m cab_tui --check`
            # will then exit 99 and Test- returns $false → the orchestrator's
            # `-Tui` path errors out per the documented contract.
            $env:PATH = "$shimDir$sep$origPath"
            $output = & pwsh -NoLogo -NoProfile -File $script:orch setup -Tui 2>&1
            $LASTEXITCODE | Should -Not -Be 0
            ($output -join "`n") | Should -Match '(?i)cab-tui is not available'
        } finally {
            $env:PATH = $origPath
            Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
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
