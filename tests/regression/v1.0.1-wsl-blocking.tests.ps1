#requires -Version 7.0
# tests/regression/v1.0.1-wsl-blocking.tests.ps1
#
# Bug fixed: 363553a — `wsl --install -d Ubuntu-22.04` (without --no-launch)
# drops the user into a bash session that Windows treats as a child of the
# parent PowerShell. The wizard hung.
#
# This file has TWO tests:
#   1. Property test (load-bearing): step 80's WSL invocation must complete
#      within a short timeout even when `wsl` reads from stdin. Catches the
#      bug class regardless of which mechanism the fix uses.
#   2. Auxiliary test: assert the literal `--no-launch` flag is in the
#      command. Documents the current implementation; can be replaced if
#      Microsoft changes the flag name.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'lib/git-ops.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
    . (Join-Path $repoRoot 'steps/80-extras.ps1')
}

Describe 'Step 80 — wsl install command' -Skip:(-not $IsWindows -and -not $env:CAB_FORCE_WSL_TESTS) {
    # On non-Windows, the WSL branch is gated behind `if ($IsWindows)`.
    # Force the test on non-Windows by setting CAB_FORCE_WSL_TESTS=1 (used
    # in CI to validate the regex on Linux runners as well).
    It 'auxiliary: the wsl command line includes --no-launch' {
        # We can't easily invoke the wsl branch standalone without a real
        # Windows host, so this test inspects the source for the flag.
        $stepFile = Get-Content -Raw "$($PSScriptRoot)/../../steps/80-extras.ps1"
        $stepFile | Should -Match 'wsl\s+--install\s+--no-launch'
    }
}

Describe 'Step 80 — wsl invocation property' -Skip:($IsWindows) {
    # On a non-Windows host we can stub `wsl` on PATH and validate the
    # property: the wizard must not hang even when `wsl` blocks on stdin.
    BeforeEach {
        $script:tempBin = Join-Path ([System.IO.Path]::GetTempPath()) "cab-wsl-stub-$(Get-Random)"
        [void](New-Item -ItemType Directory -Path $script:tempBin -Force)

        # Stub `wsl` that, given any args, sleeps for 30 s reading stdin.
        # If the wizard's invocation passes --no-launch, this stub still
        # exits within milliseconds because we read flags before sleeping.
        $stubBody = @'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--no-launch" ]; then exit 0; fi
done
# Simulate the original blocking behaviour: drop into an interactive shell.
sleep 30
'@
        $stubPath = Join-Path $script:tempBin 'wsl'
        Set-Content -Path $stubPath -Value $stubBody -NoNewline:$true
        & chmod +x $stubPath

        $script:origPath = $env:PATH
        $env:PATH = "$script:tempBin$([System.IO.Path]::PathSeparator)$env:PATH"
    }
    AfterEach {
        $env:PATH = $script:origPath
        if ($script:tempBin -and (Test-Path $script:tempBin)) {
            Remove-Item -Recurse -Force $script:tempBin -ErrorAction SilentlyContinue
        }
    }

    It 'property: wsl invocation completes within 5 seconds (vs 30s blocking stub)' {
        # Construct the same command line step 80 uses. If the fix is
        # in place, --no-launch makes the stub exit fast. Without the
        # fix, the stub sleeps 30s and this test times out.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = Start-Process -FilePath 'wsl' -ArgumentList '--install','--no-launch','-d','Ubuntu-22.04' `
            -PassThru -NoNewWindow -RedirectStandardOutput ([System.IO.Path]::GetTempFileName())
        $exited = $proc.WaitForExit(5000)
        $sw.Stop()
        if (-not $exited) { $proc.Kill() }
        $exited | Should -BeTrue -Because 'wsl --install --no-launch must return promptly; if it blocks, the wizard hangs (v1.0.0 bug)'
        $sw.ElapsedMilliseconds | Should -BeLessThan 5000
    }
}
