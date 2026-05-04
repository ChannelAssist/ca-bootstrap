#requires -Version 7.0
# lib/tui-rpc.ps1 — JSON-RPC bridge to the cab-tui Python front-end.
#
# Phase 2 implementation. Spawns the Python process, framing-handshakes
# (welcome → ack), then provides Send-CABTuiEvent and Receive-CABTuiAnswer
# helpers that the steps can call when $Context.TuiMode is true.
#
# Wire format: line-delimited JSON over stdio. Spec: docs/rpc-protocol.md.

$Script:CABTuiProcess = $null
$Script:CABTuiSchemaVersion = 1

function Test-CABTuiAvailable {
    [CmdletBinding()]
    param([string]$PythonBinary)
    if (-not $PythonBinary) {
        $PythonBinary = if ($IsWindows) { 'python.exe' } else { 'python3' }
    }
    if (-not (Get-Command $PythonBinary -ErrorAction SilentlyContinue)) { return $false }
    & $PythonBinary -m cab_tui --check 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Start-CABTuiBridge — spawn the Python child. Returns the process object;
# also stashes it in $Script:CABTuiProcess so the per-message helpers can
# find it without threading state through every caller.
function Start-CABTuiBridge {
    [CmdletBinding()]
    param(
        [string]$PythonBinary,
        [string]$Command,
        [string]$Version
    )
    if (-not $PythonBinary) {
        $PythonBinary = if ($IsWindows) { 'python.exe' } else { 'python3' }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonBinary
    $psi.Arguments = '-m cab_tui --rpc'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $Script:CABTuiProcess = $proc

    # Handshake: send welcome, await ack. 5s budget.
    Send-CABTuiEvent -Event @{
        type           = 'welcome'
        version        = $Version
        schema_version = $Script:CABTuiSchemaVersion
        command        = $Command
    }
    $ack = Receive-CABTuiMessage -TimeoutMs 5000
    if (-not $ack -or $ack.type -ne 'ack' -or $ack.of -ne 'welcome') {
        Stop-CABTuiBridge
        throw "cab-tui handshake failed (expected ack of welcome, got: $($ack | ConvertTo-Json -Compress))"
    }
    return $proc
}

function Send-CABTuiEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Event)
    if (-not $Script:CABTuiProcess -or $Script:CABTuiProcess.HasExited) {
        throw 'cab-tui process is not running'
    }
    $json = $Event | ConvertTo-Json -Compress -Depth 6
    $Script:CABTuiProcess.StandardInput.WriteLine($json)
    $Script:CABTuiProcess.StandardInput.Flush()
}

# Receive-CABTuiMessage — blocking read of one line, parsed as JSON.
# Times out after $TimeoutMs (default infinite). Returns $null on timeout.
function Receive-CABTuiMessage {
    [CmdletBinding()]
    param([int]$TimeoutMs = -1)
    if (-not $Script:CABTuiProcess) { throw 'cab-tui process is not running' }
    $reader = $Script:CABTuiProcess.StandardOutput
    $line = if ($TimeoutMs -gt 0) {
        $task = $reader.ReadLineAsync()
        if ($task.Wait($TimeoutMs)) { $task.Result } else { return $null }
    } else {
        $reader.ReadLine()
    }
    if ($null -eq $line) { return $null }
    return ($line | ConvertFrom-Json -AsHashtable)
}

# Receive-CABTuiAnswer — wait for an `answer` whose id matches $PromptId.
# Drops other messages (e.g. `quit`) onto $Script:CABTuiPendingMessages
# so the orchestrator can react to them between steps.
$Script:CABTuiPendingMessages = New-Object System.Collections.Generic.List[hashtable]
function Receive-CABTuiAnswer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PromptId,
        [int]$TimeoutMs = -1
    )
    while ($true) {
        $msg = Receive-CABTuiMessage -TimeoutMs $TimeoutMs
        if (-not $msg) { return $null }
        if ($msg.type -eq 'answer' -and $msg.id -eq $PromptId) {
            return $msg.value
        }
        # Stash anything else; the main loop drains it.
        $Script:CABTuiPendingMessages.Add($msg)
        if ($msg.type -eq 'quit') {
            # User pressed q in the TUI — propagate immediately.
            return 'quit'
        }
    }
}

function Get-CABTuiPendingMessages {
    $msgs = $Script:CABTuiPendingMessages.ToArray()
    $Script:CABTuiPendingMessages.Clear()
    return $msgs
}

function Stop-CABTuiBridge {
    [CmdletBinding()]
    param([int]$ExitCode = 0, [string]$Summary = '')
    if (-not $Script:CABTuiProcess) { return }
    if (-not $Script:CABTuiProcess.HasExited) {
        try {
            Send-CABTuiEvent -Event @{ type = 'done'; exit_code = $ExitCode; summary = $Summary }
            $Script:CABTuiProcess.StandardInput.Close()
        } catch { }
        # Give the TUI 2s to drain and exit gracefully, then terminate.
        if (-not $Script:CABTuiProcess.WaitForExit(2000)) {
            try { $Script:CABTuiProcess.Kill() } catch { }
        }
    }
    $Script:CABTuiProcess = $null
}

# Functions exported automatically when this file is dot-sourced.
