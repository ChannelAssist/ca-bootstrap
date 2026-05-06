#requires -Version 7.0
# tests/lib/write-host-tui.tests.ps1 — Pester coverage for the global
# Write-Host override installed by Install-CABTuiHostHooks.
#
# The override exists to prevent step-module Write-Host calls from
# polluting the user's terminal during a TUI session — they used to
# write to PowerShell's stdout (= the same /dev/tty Textual is
# rendering alt-screen on), causing visible flashes as Textual
# repainted over the polluted bytes. The override routes them as
# `log` events over the bridge instead. See lib/tui-rpc.ps1 for the
# full architectural rationale.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/tui-rpc.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')

    # Stub bridge: no real subprocess needed to test the override —
    # we just need an object with HasExited + StandardInput.WriteLine
    # so Send-CABTuiEvent (called via Send-CABTuiLog) can capture the
    # JSON line we're about to assert against.
    function New-StubBridge {
        $captured = New-Object System.Collections.Generic.List[string]
        $stdin = [PSCustomObject]@{ Captured = $captured }
        $stdin | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($line) $this.Captured.Add($line)
        }
        $stdin | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
        $proc = [PSCustomObject]@{
            HasExited     = $false
            StandardInput = $stdin
        }
        return $proc
    }

    # Capture Write-Host output via the Information stream (PowerShell
    # 5.1+). Write-Host doesn't go through [Console]::Out — it goes to
    # the host UI AND the Information stream. `6>&1` redirects stream 6
    # (Information) into the success stream so we can see what reached
    # the cmdlet (or conversely, that nothing did when the override
    # short-circuits to the TUI path).
    function Invoke-WithConsoleCapture {
        param([scriptblock]$ScriptBlock)
        $records = & $ScriptBlock 6>&1
        # Some records are InformationRecord objects (from Write-Host),
        # others are plain strings (success stream). Coerce to text and
        # join with newlines so the assertions can compare against the
        # raw message text.
        return ($records | ForEach-Object { $_.ToString() }) -join "`n"
    }

    function Reset-CABTuiState {
        # Reset state between tests so prior fixtures don't leak.
        # Drain-CABTuiPending & friends key off these globals.
        $Script:CABTuiProcess = $null
        $Script:CABootstrapTuiMode = $false
        $Script:CABTuiHandshakeComplete = $false
    }
}

AfterAll {
    # Drop the override we installed during the test run so subsequent
    # Pester files (or anything else in the session) see the real cmdlet
    # again. Remove-Item silently ignores a missing function.
    Remove-Item function:global:Write-Host -ErrorAction SilentlyContinue
    Remove-Variable -Scope Script -Name '_CABTuiHostHooksInstalled' -ErrorAction SilentlyContinue
    Reset-CABTuiState
}

Describe 'Install-CABTuiHostHooks' {
    BeforeEach {
        Reset-CABTuiState
        # Each test installs cleanly: drop any leftover override + flag.
        Remove-Item function:global:Write-Host -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name '_CABTuiHostHooksInstalled' -ErrorAction SilentlyContinue
        Install-CABTuiHostHooks
    }

    It 'is idempotent (second install is a no-op)' {
        # Calling install twice should not throw or otherwise misbehave.
        # Specifically: the function lookup must still resolve to the
        # override, and CABTuiHostHooksInstalled must still be set.
        Install-CABTuiHostHooks
        (Get-Command Write-Host -CommandType Function -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        $Script:_CABTuiHostHooksInstalled | Should -BeTrue
    }

    It 'routes Write-Host to a `log` event when TUI mode is active and bridge is alive' {
        $bridge = New-StubBridge
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $true

        $output = Invoke-WithConsoleCapture { Write-Host 'hello from a step' }

        $output | Should -BeNullOrEmpty
        $bridge.StandardInput.Captured.Count | Should -Be 1
        $sent = $bridge.StandardInput.Captured[0] | ConvertFrom-Json
        $sent.type | Should -Be 'log'
        $sent.stream | Should -Be 'info'
        $sent.text | Should -Be 'hello from a step'
    }

    It 'maps -ForegroundColor Red to stream=error so the TUI transcript can render it as an error' {
        $bridge = New-StubBridge
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $true

        Write-Host 'something broke' -ForegroundColor Red | Out-Null

        $sent = $bridge.StandardInput.Captured[0] | ConvertFrom-Json
        $sent.stream | Should -Be 'error'
        $sent.text | Should -Be 'something broke'
    }

    It 'maps -ForegroundColor Yellow to stream=warn' {
        $bridge = New-StubBridge
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $true

        Write-Host 'be careful' -ForegroundColor Yellow | Out-Null

        $sent = $bridge.StandardInput.Captured[0] | ConvertFrom-Json
        $sent.stream | Should -Be 'warn'
    }

    It 'falls through to the real Write-Host when TUI mode is off' {
        $bridge = New-StubBridge
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $false   # CLI mode

        $output = Invoke-WithConsoleCapture { Write-Host 'cli-line' }

        # Real cmdlet wrote to console; bridge inbox stays empty.
        $output.TrimEnd() | Should -Be 'cli-line'
        $bridge.StandardInput.Captured.Count | Should -Be 0
    }

    It 'falls through to the real Write-Host when the bridge has exited mid-flow' {
        $bridge = New-StubBridge
        $bridge.HasExited = $true
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $true   # mode says TUI but bridge died

        $output = Invoke-WithConsoleCapture { Write-Host 'after bridge died' }

        # Output went to console (CLI fallback), not into the bridge.
        $output.TrimEnd() | Should -Be 'after bridge died'
        $bridge.StandardInput.Captured.Count | Should -Be 0
    }

    It 'forwards Write-Host parameters to the real cmdlet on the CLI fallback path' {
        $Script:CABTuiProcess = $null
        $Script:CABootstrapTuiMode = $false

        # The override should forward all parameters (including
        # -NoNewline) to the real cmdlet without throwing or dropping
        # messages. The Information stream emits one record per
        # Write-Host call regardless of -NoNewline (joining is a
        # console-rendering concern), so we assert both pieces made
        # it through rather than asserting a particular joined form.
        $output = Invoke-WithConsoleCapture {
            Write-Host 'piece1' -NoNewline
            Write-Host 'piece2'
        }

        $output | Should -Match 'piece1'
        $output | Should -Match 'piece2'
    }

    It 'joins multiple positional arguments with -Separator on the TUI path' {
        $bridge = New-StubBridge
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $true

        Write-Host 'a','b','c' -Separator '|' | Out-Null

        $sent = $bridge.StandardInput.Captured[0] | ConvertFrom-Json
        $sent.text | Should -Be 'a|b|c'
    }

    It 'sends an empty `log` event for `Write-Host` with no args (blank line)' {
        $bridge = New-StubBridge
        $Script:CABTuiProcess = $bridge
        $Script:CABootstrapTuiMode = $true

        Write-Host '' | Out-Null

        $bridge.StandardInput.Captured.Count | Should -Be 1
        $sent = $bridge.StandardInput.Captured[0] | ConvertFrom-Json
        $sent.text | Should -Be ''
    }
}
