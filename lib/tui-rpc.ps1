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

# Path to the cab-tui package directory next to this lib/. Used to seed
# PYTHONPATH for the python3 invocations below — Python 3.14 skips .pth
# files whose names start with underscore, and hatchling's editable
# backend writes `_editable_impl_<pkg>.pth`, so `python3 -m cab_tui`
# would otherwise fail unless CWD happens to be the cab-tui dir.
function Get-CABTuiPackagePath {
    Join-Path (Split-Path -Parent $PSScriptRoot) 'cab-tui'
}

# Build a PYTHONPATH that prepends the cab-tui dir to whatever the user
# already has. Returns a pair: the value to assign and the original
# value to restore after.
function _CABTuiPythonPath {
    $cabPath = Get-CABTuiPackagePath
    $sep = if ($IsWindows) { ';' } else { ':' }
    $existing = $env:PYTHONPATH
    if ($existing) { return @{ Set = "$cabPath$sep$existing"; Original = $existing } }
    return @{ Set = $cabPath; Original = $null }
}

function Test-CABTuiAvailable {
    [CmdletBinding()]
    param([string]$PythonBinary)
    if (-not $PythonBinary) {
        $PythonBinary = if ($IsWindows) { 'python.exe' } else { 'python3' }
    }
    if (-not (Get-Command $PythonBinary -ErrorAction SilentlyContinue)) { return $false }
    $pp = _CABTuiPythonPath
    $original = $pp.Original
    $env:PYTHONPATH = $pp.Set
    try {
        & $PythonBinary -m cab_tui --check 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        if ($null -eq $original) { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
        else                     { $env:PYTHONPATH = $original }
    }
}

# Start-CABTuiBridge — spawn the Python child. Returns the process object;
# also stashes it in $Script:CABTuiProcess so the per-message helpers can
# find it without threading state through every caller.
function Start-CABTuiBridge {
    [CmdletBinding()]
    param(
        [string]$PythonBinary,
        [string]$Command,
        [string]$Version,
        # Override the child's command-line. Default invokes the cab_tui
        # module in --rpc mode; tests use this to spawn a stub that
        # speaks the protocol without needing a TTY.
        [string]$Arguments = '-m cab_tui --rpc'
    )
    if (-not $PythonBinary) {
        $PythonBinary = if ($IsWindows) { 'python.exe' } else { 'python3' }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PythonBinary
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    # See _CABTuiPythonPath: ensures cab_tui resolves regardless of CWD
    # under Python 3.14's stricter .pth handling.
    $pp = _CABTuiPythonPath
    $psi.EnvironmentVariables['PYTHONPATH'] = $pp.Set

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

# Send-CABTuiProgress — emit a `progress` event for the given indicator id.
# Determinate: pass -Total + -Current for a ProgressBar.
# Indeterminate: omit -Total for a LoadingIndicator spinner.
# Closing: pass -Done to remove the indicator.
# No-op when the bridge isn't running, so step files can call this
# unconditionally without first checking $Script:CABootstrapTuiMode.
function Send-CABTuiProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [int]$Current,
        [int]$Total,
        [string]$Label = '',
        [switch]$Done
    )
    if (-not $Script:CABTuiProcess -or $Script:CABTuiProcess.HasExited) { return }
    $event = @{ type = 'progress'; id = $Id }
    if ($Done) {
        $event.done = $true
    } else {
        if ($PSBoundParameters.ContainsKey('Current')) { $event.current = $Current }
        if ($PSBoundParameters.ContainsKey('Total'))   { $event.total   = $Total }
        if ($Label) { $event.label = $Label }
    }
    # Best-effort: a progress update should NEVER abort the host step.
    # The HasExited check above is a TOCTOU guard at best — the bridge
    # can die between the check and the WriteLine, leaving us with a
    # broken pipe. Step files that call this helper unconditionally
    # would otherwise propagate that throw and crash setup.
    try {
        Send-CABTuiEvent -Event $event
    } catch {
        # Swallow: the consumer half of the bridge has gone away. The
        # next user-driven prompt will trigger Invoke-CABTuiPrompt's
        # fallback path, which formally disables TuiMode and writes a
        # warning to the user.
    }
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
