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
