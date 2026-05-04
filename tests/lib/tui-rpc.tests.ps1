#requires -Version 7.0
# tests/lib/tui-rpc.tests.ps1 — Pester tests for the TUI RPC bridge.
#
# Covers the PowerShell side of the JSON-RPC over stdio protocol
# (lib/tui-rpc.ps1). Spawns a tiny Python stub (or another pwsh script)
# as the "child" and asserts the message exchange.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/tui-rpc.ps1')

    # Tests use a stub child that doesn't honor the post-`done` "let the
    # user dismiss" contract, so Stop-CABTuiBridge would otherwise wait
    # the full 300s default. Force a short timeout so the suite stays fast.
    $env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT = '2'

    # Helper: launch a pwsh subprocess with a tiny scriptblock as the
    # "child" so we don't need Python on the runner to test the wire
    # protocol. The scriptblock reads JSON lines from stdin and writes
    # JSON lines to stdout.
    function Start-StubChild {
        param([string]$ScriptBody)
        $script:stubFile = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tuirpc-stub-$(Get-Random).ps1"
        Set-Content -Path $script:stubFile -Value $ScriptBody

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path  # same pwsh
        $psi.Arguments = "-NoLogo -NoProfile -File `"$script:stubFile`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $Script:CABTuiProcess = $proc
        return $proc
    }
    function Cleanup-StubChild {
        if ($Script:CABTuiProcess -and -not $Script:CABTuiProcess.HasExited) {
            try { $Script:CABTuiProcess.Kill() } catch { }
        }
        if ($script:stubFile -and (Test-Path $script:stubFile)) {
            Remove-Item $script:stubFile -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Find-CABPython' {
    It 'returns a usable Python 3.10+ binary if one is installed' {
        # The dev workflow has python3 (and the cab-tui venv); CI does too.
        $py = Find-CABPython
        if ($py) {
            $verLine = & $py -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>$null
            $verLine | Should -Match '^3\.(1[0-9]|[2-9]\d)'
        } else {
            Set-ItResult -Skipped -Because 'no Python 3.10+ on PATH; nothing to assert'
        }
    }
}

Describe 'Drain-CABTuiPending pre-handshake gating' {
    AfterEach { Stop-CABTuiBridge }

    It 'does NOT consume the welcome ack even when the child replies fast' {
        # Regression for iter-8 #1: Drain-CABTuiPending was added to
        # Send-CABTuiEvent's tail in iter 4. If the child acks fast
        # enough that Drain runs before the handshake's
        # Receive-CABTuiMessage, Drain would have consumed the ack into
        # CABTuiPendingMessages and the handshake would spuriously time
        # out. The fix gates Drain on $CABTuiHandshakeComplete.
        $body = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
if ($msg.type -eq 'welcome') {
    # Reply IMMEDIATELY — same line, before any sleep — so the ack
    # lands in the inbox while the parent is still inside Send.
    [Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
    [Console]::Out.Flush()
}
Start-Sleep -Seconds 5
'@
        $script:fastAckStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-fastack-$(Get-Random).ps1"
        Set-Content $script:fastAckStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:fastAckStub`""
        # If Drain stole the ack, this would throw "handshake failed".
        $proc = Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path `
            -Command 'setup' -Version 'test' -Arguments $stubArgs
        $proc | Should -Not -BeNullOrEmpty
        $Script:CABTuiHandshakeComplete | Should -BeTrue
        Remove-Item $script:fastAckStub -Force -ErrorAction SilentlyContinue
    }
}

Describe '_ParseCABTuiLine fatal teardown' {
    AfterEach { Stop-CABTuiBridge }

    It 'kills the child process on parse failure (so Stop does not wait the dismiss timeout)' {
        # Regression for iter-8 #2: _ParseCABTuiLine was only setting
        # the fatal flag and returning $null; the bridge process was
        # left running and Stop-CABTuiBridge would wait the full 300s
        # dismiss timeout against a child that was already in a fatal
        # protocol state. Now Parse tears down (close stdin + kill).
        $body = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
if ($msg.type -eq 'welcome') {
    [Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
    [Console]::Out.Flush()
    # Then emit a malformed line.
    [Console]::Out.WriteLine('this is not json')
    [Console]::Out.Flush()
}
Start-Sleep -Seconds 30   # pretend to be a long-running TUI
'@
        $script:badLineStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-badline-$(Get-Random).ps1"
        Set-Content $script:badLineStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:badLineStub`""
        $env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT = '60'   # generous so we'd notice a real wait
        $proc = Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path `
            -Command 'setup' -Version 'test' -Arguments $stubArgs

        # Wait briefly so the bad line lands in the inbox, then drain.
        Start-Sleep -Milliseconds 300
        $Script:CABFatalProtocolError = $false
        Drain-CABTuiPending
        $Script:CABFatalProtocolError | Should -BeTrue
        # Drain should have killed the child.
        Start-Sleep -Milliseconds 200
        $proc.HasExited | Should -BeTrue

        Remove-Item $script:badLineStub -Force -ErrorAction SilentlyContinue
        $env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT = '2'
    }
}

Describe 'Drain-CABTuiPending + Send-CABTuiEvent quit-surfacing' {
    AfterEach { Stop-CABTuiBridge }

    It 'surfaces a `quit` from the child during a long step (no prompt waiting)' {
        # Stub child: ack the welcome, then immediately emit `quit`. The
        # orchestrator path during a long step would call Send-CABTuiEvent
        # (e.g. for a progress update) and the embedded Drain should
        # set $Script:CABQuitRequested.
        $body = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
if ($msg.type -eq 'welcome') {
    [Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
    [Console]::Out.Flush()
    Start-Sleep -Milliseconds 100
    [Console]::Out.WriteLine('{"type":"quit"}')
    [Console]::Out.Flush()
}
Start-Sleep -Seconds 5
'@
        $script:quitStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-quit-$(Get-Random).ps1"
        Set-Content $script:quitStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:quitStub`""
        Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path `
            -Command 'setup' -Version 'test' -Arguments $stubArgs | Out-Null

        # Reset the flag, then simulate the orchestrator emitting a step
        # event during a long-running step. Wait briefly for the inbox
        # to deliver the quit.
        $Script:CABQuitRequested = $false
        Start-Sleep -Milliseconds 200
        Send-CABTuiEvent -Event @{ type = 'log'; stream = 'info'; text = 'busy with clones…' }

        # Drain may have already happened inside Send-CABTuiEvent; if the
        # quit hadn't landed yet, give it one more cycle.
        if (-not $Script:CABQuitRequested) {
            Start-Sleep -Milliseconds 200
            Drain-CABTuiPending
        }
        $Script:CABQuitRequested | Should -BeTrue

        Remove-Item $script:quitStub -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-CABTuiAvailable' {
    It 'returns $false when the python binary is not on PATH' {
        # A binary name that no system would have.
        Test-CABTuiAvailable -PythonBinary 'definitely-not-a-real-python-9999' | Should -BeFalse
    }

    It 'returns $false when python is present but cab_tui module is not importable' {
        # Use the host pwsh as a stand-in for a python binary: -m cab_tui --check
        # will fail (pwsh doesn't speak `-m`), exiting non-zero. That's the
        # exact failure mode we want to detect: probe runs, exit != 0.
        $hostPwsh = (Get-Process -Id $PID).Path
        Test-CABTuiAvailable -PythonBinary $hostPwsh | Should -BeFalse
    }

    It 'returns $true when cab_tui --check exits 0' {
        # Use this test's own venv if one exists alongside the cab-tui dir
        # (created in the dev workflow via `python3 -m venv cab-tui/.venv`).
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $venvPython = if ($IsWindows) {
            Join-Path $repoRoot 'cab-tui/.venv/Scripts/python.exe'
        } else {
            Join-Path $repoRoot 'cab-tui/.venv/bin/python3'
        }
        if (-not (Test-Path $venvPython)) {
            Set-ItResult -Skipped -Because 'cab-tui/.venv not present in this checkout'
            return
        }
        Test-CABTuiAvailable -PythonBinary $venvPython | Should -BeTrue
    }
}

Describe 'Send-CABTuiEvent' {
    BeforeEach {
        # Stub child that just echoes every line back, prefixed with "echo:".
        # Useful for verifying our outbound serialization without coupling
        # to specific event handling.
        $body = @'
$line = [Console]::In.ReadLine()
[Console]::Out.WriteLine("echo:$line")
[Console]::Out.Flush()
'@
        Start-StubChild -ScriptBody $body | Out-Null
    }
    AfterEach { Cleanup-StubChild }

    It 'serializes a hashtable to one line of JSON' {
        Send-CABTuiEvent -Event @{ type = 'log'; stream = 'info'; text = 'hello' }
        $line = $Script:CABTuiProcess.StandardOutput.ReadLine()
        $line | Should -Match '^echo:'
        $payload = $line.Substring(5) | ConvertFrom-Json -AsHashtable
        $payload.type   | Should -Be 'log'
        $payload.stream | Should -Be 'info'
        $payload.text   | Should -Be 'hello'
    }

    It 'handles non-ASCII characters via UTF-8 encoding' {
        Send-CABTuiEvent -Event @{ type = 'log'; text = 'Émilie Müller — café' }
        $line = $Script:CABTuiProcess.StandardOutput.ReadLine()
        $payload = $line.Substring(5) | ConvertFrom-Json -AsHashtable
        $payload.text | Should -Be 'Émilie Müller — café'
    }

    It 'throws if the child has already exited' {
        # Send once to consume the stub's single line; child then exits.
        Send-CABTuiEvent -Event @{ type = 'a' }
        $Script:CABTuiProcess.StandardOutput.ReadLine() | Out-Null
        $Script:CABTuiProcess.WaitForExit(2000) | Out-Null
        { Send-CABTuiEvent -Event @{ type = 'b' } } | Should -Throw '*not running*'
    }
}

Describe 'Send-CABTuiProgress' {
    BeforeEach {
        $body = @'
$line = [Console]::In.ReadLine()
[Console]::Out.WriteLine("echo:$line")
[Console]::Out.Flush()
'@
        Start-StubChild -ScriptBody $body | Out-Null
    }
    AfterEach { Cleanup-StubChild }

    It 'serializes determinate progress (id + current + total + label)' {
        Send-CABTuiProgress -Id 'clone-batch' -Current 3 -Total 14 -Label 'ChannelAssist/Keystone'
        $line = $Script:CABTuiProcess.StandardOutput.ReadLine()
        $payload = $line.Substring(5) | ConvertFrom-Json -AsHashtable
        $payload.type    | Should -Be 'progress'
        $payload.id      | Should -Be 'clone-batch'
        $payload.current | Should -Be 3
        $payload.total   | Should -Be 14
        $payload.label   | Should -Be 'ChannelAssist/Keystone'
        $payload.ContainsKey('done') | Should -BeFalse
    }

    It 'serializes indeterminate progress (no total → spinner)' {
        Send-CABTuiProgress -Id 'install-docker' -Label 'Installing Docker Desktop…'
        $line = $Script:CABTuiProcess.StandardOutput.ReadLine()
        $payload = $line.Substring(5) | ConvertFrom-Json -AsHashtable
        $payload.type  | Should -Be 'progress'
        $payload.id    | Should -Be 'install-docker'
        $payload.label | Should -Be 'Installing Docker Desktop…'
        $payload.ContainsKey('total')   | Should -BeFalse
        $payload.ContainsKey('current') | Should -BeFalse
    }

    It 'serializes a close (done=$true) message' {
        Send-CABTuiProgress -Id 'install-docker' -Done
        $line = $Script:CABTuiProcess.StandardOutput.ReadLine()
        $payload = $line.Substring(5) | ConvertFrom-Json -AsHashtable
        $payload.type | Should -Be 'progress'
        $payload.id   | Should -Be 'install-docker'
        $payload.done | Should -Be $true
    }

    It 'is a no-op when no bridge is running (does not throw)' {
        Cleanup-StubChild
        $Script:CABTuiProcess = $null
        # Step files call this unconditionally — must not blow up in CLI mode.
        { Send-CABTuiProgress -Id 'x' -Current 1 -Total 5 } | Should -Not -Throw
    }

    It 'swallows mid-call bridge failures (TOCTOU between HasExited and WriteLine)' {
        # The HasExited check at function entry is best-effort: the child
        # can die between that check and the WriteLine. We simulate that
        # window by killing the stub then calling Send before the next
        # poll. Send-CABTuiEvent throws "process is not running" because
        # HasExited flips $true once the OS reaps it; the helper must
        # catch and swallow rather than abort the host step.
        $Script:CABTuiProcess.Kill()
        $Script:CABTuiProcess.WaitForExit(2000) | Out-Null
        { Send-CABTuiProgress -Id 'x' -Current 2 -Total 5 -Label 'bar' } | Should -Not -Throw
        { Send-CABTuiProgress -Id 'x' -Done } | Should -Not -Throw
    }
}

Describe 'Receive-CABTuiMessage' {
    BeforeEach {
        # Child writes one JSON line then sleeps so the parent can read.
        $body = @'
[Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
[Console]::Out.Flush()
Start-Sleep -Seconds 5
'@
        Start-StubChild -ScriptBody $body | Out-Null
    }
    AfterEach { Cleanup-StubChild }

    It 'parses one inbound line into a hashtable' {
        $msg = Receive-CABTuiMessage -TimeoutMs 5000
        $msg.type | Should -Be 'ack'
        $msg.of   | Should -Be 'welcome'
    }

    It 'returns $null on timeout when the child is silent' {
        # First read consumes the ack the stub wrote.
        Receive-CABTuiMessage -TimeoutMs 5000 | Out-Null
        # Child is now sleeping; second read should time out fast.
        $msg = Receive-CABTuiMessage -TimeoutMs 200
        $msg | Should -BeNullOrEmpty
    }
}

Describe 'Stop-CABTuiBridge dismiss-timeout contract' {
    AfterEach {
        if ($Script:CABTuiProcess -and -not $Script:CABTuiProcess.HasExited) {
            try { $Script:CABTuiProcess.Kill() } catch { }
        }
        $Script:CABTuiProcess = $null
        if ($script:dismissStub -and (Test-Path $script:dismissStub)) {
            Remove-Item $script:dismissStub -Force -ErrorAction SilentlyContinue
        }
    }

    It 'sends `done` without immediately closing stdin so the user can dismiss the TUI' {
        # Stub: ack the welcome, then read until EOF and emit anything
        # received to a side-channel file so we can verify what the parent
        # actually sent during shutdown.
        $captured = Join-Path ([System.IO.Path]::GetTempPath()) "cab-dismiss-cap-$(Get-Random).jsonl"
        $body = @"
`$out = '$($captured -replace '\\','\\')'
`$line = [Console]::In.ReadLine()
`$msg = `$line | ConvertFrom-Json
if (`$msg.type -eq 'welcome') {
    [Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
    [Console]::Out.Flush()
}
while (`$true) {
    `$line = [Console]::In.ReadLine()
    if (`$null -eq `$line) { break }
    Add-Content -Path `$out -Value `$line
}
"@
        $script:dismissStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-dismiss-$(Get-Random).ps1"
        Set-Content $script:dismissStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:dismissStub`""

        # Run with a tight timeout so the test is fast; production default
        # is 300s but we just want to verify the `done` event shape.
        $env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT = '3'
        Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path `
            -Command 'setup' -Version 'test' -Arguments $stubArgs | Out-Null

        # Stop should send `done` and wait the dismiss-timeout. Stub stays
        # in its read loop until stdin closes (which only happens after
        # the timeout expires + the safety-net stdin.Close()).
        Stop-CABTuiBridge -ExitCode 0 -Summary '8 steps complete'

        Test-Path $captured | Should -BeTrue
        $events = Get-Content $captured | ForEach-Object { $_ | ConvertFrom-Json }
        $doneEvent = $events | Where-Object { $_.type -eq 'done' } | Select-Object -First 1
        $doneEvent | Should -Not -BeNullOrEmpty
        $doneEvent.exit_code | Should -Be 0
        $doneEvent.summary | Should -Be '8 steps complete'

        Remove-Item $captured -Force -ErrorAction SilentlyContinue
    }

    It 'CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT=0 means wait indefinitely (until child exits naturally)' {
        # Stub: ack and exit immediately. With timeout=0, Stop-CABTuiBridge
        # would wait forever — but since the child exits on its own right
        # away, the test still completes quickly. This proves the "no
        # forced kill" path actually waits.
        $body = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
if ($msg.type -eq 'welcome') {
    [Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
    [Console]::Out.Flush()
}
exit 0
'@
        $script:dismissStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-dismiss-$(Get-Random).ps1"
        Set-Content $script:dismissStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:dismissStub`""

        $env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT = '0'
        $proc = Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path `
            -Command 'setup' -Version 'test' -Arguments $stubArgs
        # Bound the test itself with a watchdog: if Stop hangs, fail fast.
        $job = Start-Job { param($p) Start-Sleep -Seconds 5; if (-not $p.HasExited) { $p.Kill() } } -ArgumentList $proc
        try {
            Stop-CABTuiBridge
            $proc.HasExited | Should -BeTrue
            $proc.ExitCode | Should -Be 0
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -ErrorAction SilentlyContinue
            $env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT = '2'
        }
    }
}

Describe 'Start-CABTuiBridge handshake' {
    AfterEach {
        Stop-CABTuiBridge
        if ($script:handshakeStub -and (Test-Path $script:handshakeStub)) {
            Remove-Item $script:handshakeStub -Force -ErrorAction SilentlyContinue
        }
    }

    It 'completes when the child acks within the timeout' {
        # Stub child speaks the protocol: read welcome → emit ack → idle.
        # Spawn pwsh via Start-CABTuiBridge's -Arguments seam (added to
        # support exactly this kind of test without bypassing the public
        # API).
        $body = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
if ($msg.type -eq 'welcome') {
    [Console]::Out.WriteLine('{"type":"ack","of":"welcome"}')
    [Console]::Out.Flush()
    Start-Sleep -Seconds 5
}
'@
        $script:handshakeStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-handshake-$(Get-Random).ps1"
        Set-Content $script:handshakeStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:handshakeStub`""
        $proc = Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path -Command 'setup' -Version 'test' -Arguments $stubArgs
        $proc | Should -Not -BeNullOrEmpty
        $proc.HasExited | Should -BeFalse
    }

    It 'throws if the child never acks within the handshake timeout' {
        # Stub reads the welcome and goes silent — handshake should time out.
        $body = '[Console]::In.ReadLine() | Out-Null; Start-Sleep -Seconds 10'
        $script:handshakeStub = Join-Path ([System.IO.Path]::GetTempPath()) "cab-noack-$(Get-Random).ps1"
        Set-Content $script:handshakeStub $body
        $stubArgs = "-NoLogo -NoProfile -File `"$script:handshakeStub`""
        { Start-CABTuiBridge -PythonBinary (Get-Process -Id $PID).Path -Command 'setup' -Version 'test' -Arguments $stubArgs } |
            Should -Throw '*handshake failed*'
    }
}
