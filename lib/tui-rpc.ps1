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
# Inbox + background reader handle for the TUI bridge. A persistent
# PowerShell runspace pumps lines from the child's stdout into this
# BlockingCollection so Receive-CABTuiAnswer and Drain-CABTuiPending
# can both consume from a single source without leaky-task races.
$Script:CABTuiInbox = $null
$Script:CABTuiReaderInstance = $null
$Script:CABTuiReaderHandle = $null
# Set by Drain-CABTuiPending / Receive-CABTuiMessage when a malformed
# line arrives from the child. Per docs/rpc-protocol.md, parse failure
# is fatal — the caller is expected to log + tear down + fall back.
$Script:CABFatalProtocolError = $false
# Set $true once the welcome → ack handshake has completed. Until then,
# Drain-CABTuiPending must be a no-op: if it fired between the welcome
# send and the ack receive, it would consume the ack out of the inbox
# and the handshake's Receive-CABTuiMessage would time out spuriously.
$Script:CABTuiHandshakeComplete = $false

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

# Find-CABPython — return the first usable Python 3.10+ on PATH, or
# $null. Candidate order matches bootstrap.sh's detect_python and the
# Makefile's DETECT_PY: pyenv/conda environments may only ship a
# version-suffixed `python3.12` (no `python3` symlink), so we probe
# those names too — otherwise the orchestrator would silently fall
# back to CLI on a setup the installer happily accepts.
function Get-CABPythonCandidates {
    if ($IsWindows) {
        @('python.exe', 'py', 'python3', 'python3.13', 'python3.12', 'python3.11', 'python3.10', 'python')
    } else {
        @('python3', 'python3.13', 'python3.12', 'python3.11', 'python3.10', 'python')
    }
}

function Find-CABPython {
    foreach ($cand in (Get-CABPythonCandidates)) {
        if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
        try {
            $verLine = & $cand -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>$null
        } catch { continue }
        if ($verLine -match '^(\d+)\.(\d+)$') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            if ($major -ge 3 -and $minor -ge 10) { return $cand }
        }
    }
    return $null
}

function Test-CABTuiAvailable {
    [CmdletBinding()]
    param([string]$PythonBinary)
    if (-not $PythonBinary) {
        $PythonBinary = Find-CABPython
        if (-not $PythonBinary) { return $false }
    } elseif (-not (Get-Command $PythonBinary -ErrorAction SilentlyContinue)) {
        return $false
    }
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
        [string]$Arguments = '-m cab_tui --rpc',
        # Step list shipped to the TUI in the welcome event so it can
        # build its Tree pane from a single source of truth (commands/
        # setup.ps1's Get-CABSetupStepDefs). Optional; if omitted the
        # TUI falls back to its built-in default — which is the path
        # tests use to avoid threading the orchestrator's step list
        # through every harness.
        [array]$Steps = @()
    )
    if (-not $PythonBinary) {
        $PythonBinary = Find-CABPython
        if (-not $PythonBinary) {
            $tried = (Get-CABPythonCandidates) -join ' / '
            throw "cab-tui: no usable Python 3.10+ found on PATH (tried $tried)."
        }
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

    # Background reader: pumps stdout lines into a BlockingCollection.
    # Without this, asking "is a line ready?" (Drain) and "wait for the
    # next line" (Receive-CABTuiAnswer) would both have to call
    # ReadLineAsync directly on the same StreamReader — which races and
    # drops lines. With a single producer (the runspace) and bounded
    # consumer reads (TryTake / Take), there's no race.
    $Script:CABTuiInbox = [System.Collections.Concurrent.BlockingCollection[string]]::new()
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($stdout, $inbox)
        try {
            while (-not $inbox.IsAddingCompleted) {
                $line = $stdout.ReadLine()
                if ($null -eq $line) { break }   # EOF
                try { $inbox.Add($line) } catch [System.InvalidOperationException] { break }
            }
        } finally {
            try { $inbox.CompleteAdding() } catch { }
        }
    }).AddArgument($proc.StandardOutput).AddArgument($Script:CABTuiInbox)
    $Script:CABTuiReaderInstance = $ps
    $Script:CABTuiReaderHandle = $ps.BeginInvoke()

    # Handshake: send welcome, await ack. 5s budget.
    $welcome = @{
        type           = 'welcome'
        version        = $Version
        schema_version = $Script:CABTuiSchemaVersion
        command        = $Command
    }
    if ($Steps -and $Steps.Count -gt 0) { $welcome.steps = @($Steps) }
    # Reset handshake gate before sending — Send-CABTuiEvent's drain
    # call will be a no-op until we explicitly flip this $true after a
    # successful ack receive (preventing the drain-eats-ack race).
    $Script:CABTuiHandshakeComplete = $false
    Send-CABTuiEvent -Event $welcome
    $ack = Receive-CABTuiMessage -TimeoutMs 5000
    if (-not $ack -or $ack.type -ne 'ack' -or $ack.of -ne 'welcome') {
        # Handshake failed → the child is in an undefined state. Don't go
        # through Stop-CABTuiBridge (which waits for the user to dismiss
        # the TUI); just kill it now since no protocol contract applies.
        if ($Script:CABTuiProcess -and -not $Script:CABTuiProcess.HasExited) {
            try { $Script:CABTuiProcess.StandardInput.Close() } catch { }
            if (-not $Script:CABTuiProcess.WaitForExit(2000)) {
                try { $Script:CABTuiProcess.Kill() } catch { }
            }
        }
        # Reader cleanup: same teardown as Stop-CABTuiBridge does, since
        # we won't fall through to it on this error path.
        if ($Script:CABTuiInbox) { try { $Script:CABTuiInbox.CompleteAdding() } catch { } }
        if ($Script:CABTuiReaderInstance) {
            try { $Script:CABTuiReaderInstance.EndInvoke($Script:CABTuiReaderHandle) } catch { }
            try { $Script:CABTuiReaderInstance.Dispose() } catch { }
        }
        if ($Script:CABTuiInbox) { try { $Script:CABTuiInbox.Dispose() } catch { } }
        $Script:CABTuiInbox = $null
        $Script:CABTuiReaderInstance = $null
        $Script:CABTuiReaderHandle = $null
        $Script:CABTuiProcess = $null
        $Script:CABTuiHandshakeComplete = $false
        throw "cab-tui handshake failed (expected ack of welcome, got: $($ack | ConvertTo-Json -Compress))"
    }
    # Handshake complete — Drain-CABTuiPending is now safe to run.
    $Script:CABTuiHandshakeComplete = $true
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
    # Drain any inbound messages the user has queued while we weren't
    # actively waiting for an answer. Without this, a `quit` press from
    # the user during a long-running step (clones, tool installs)
    # wouldn't be acted on until the next prompt fires — which defeats
    # the documented "quit any time" guarantee. No-op when the inbox
    # isn't set up (tests that bypass Start-CABTuiBridge).
    Drain-CABTuiPending
}

# Drain-CABTuiPending — non-blocking pull of any lines the background
# reader task has pumped into $Script:CABTuiInbox. A `quit` message sets
# $Script:CABQuitRequested so the orchestrator's between-steps check
# picks it up the same way Ctrl+C does; other messages are stashed on
# $Script:CABTuiPendingMessages for the next Receive-CABTuiAnswer caller.
#
# Safe to call concurrently with Receive-CABTuiAnswer because both go
# through the same BlockingCollection — the reader task is the sole
# producer, so there's no leaky-task race like there would be if we
# called StreamReader.ReadLineAsync() directly here.
function Drain-CABTuiPending {
    [CmdletBinding()]
    param()
    if (-not $Script:CABTuiInbox) { return }
    # Pre-handshake: don't touch the inbox. The welcome → ack exchange
    # owns it exclusively until Receive-CABTuiMessage takes the ack.
    # Without this gate, a fast child can ack between our welcome send
    # and our receive, Drain consumes the ack into CABTuiPendingMessages,
    # and the handshake spuriously times out.
    if (-not $Script:CABTuiHandshakeComplete) { return }
    $line = $null
    while ($Script:CABTuiInbox.TryTake([ref]$line, 0)) {
        if ($null -eq $line) { continue }
        $msg = _ParseCABTuiLine $line
        # On parse failure _ParseCABTuiLine already logged the bytes,
        # set $CABFatalProtocolError, and torn down the bridge. We just
        # bail out of the loop so we don't process anything that may
        # still be in the inbox after a corrupted line.
        if ($null -eq $msg) { return }
        if ($msg.type -eq 'quit') {
            $Script:CABQuitRequested = $true
        } else {
            $Script:CABTuiPendingMessages.Add($msg)
        }
    }
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
#
# Two paths:
#   1. Background-reader path (when Start-CABTuiBridge has set up the
#      inbox): Take / TryTake from the BlockingCollection. This is the
#      production path. It avoids the leaky-task race that direct
#      StreamReader.ReadLineAsync would have when called from both
#      Receive and Drain.
#   2. Direct-read path (tests that bypass Start-CABTuiBridge and just
#      poke a stub child via $Script:CABTuiProcess directly): fall back
#      to ReadLineAsync. The single-reader invariant holds in those
#      tests because Drain is a no-op without the inbox.
function Receive-CABTuiMessage {
    [CmdletBinding()]
    param([int]$TimeoutMs = -1)
    if (-not $Script:CABTuiProcess) { throw 'cab-tui process is not running' }
    if ($Script:CABTuiInbox) {
        $line = $null
        try {
            if ($TimeoutMs -lt 0) {
                $line = $Script:CABTuiInbox.Take()
            } else {
                if (-not $Script:CABTuiInbox.TryTake([ref]$line, $TimeoutMs)) { return $null }
            }
        } catch [System.InvalidOperationException] {
            return $null   # CompleteAdding called → reader exited / EOF
        }
        if ($null -eq $line) { return $null }
        return _ParseCABTuiLine $line
    }
    $reader = $Script:CABTuiProcess.StandardOutput
    $line = if ($TimeoutMs -gt 0) {
        $task = $reader.ReadLineAsync()
        if ($task.Wait($TimeoutMs)) { $task.Result } else { return $null }
    } else {
        $reader.ReadLine()
    }
    if ($null -eq $line) { return $null }
    return _ParseCABTuiLine $line
}

# Shared parse path. Per docs/rpc-protocol.md, parse failure is fatal on
# the receiving side: log the offending bytes to stderr, tear down the
# bridge so a subsequent Stop-CABTuiBridge doesn't sit in its 300s
# dismiss wait against a dead-state child, and return $null so callers
# (handshake / Receive-CABTuiAnswer) fall through to their bridge-dead
# branches and disable TuiMode.
function _ParseCABTuiLine {
    param([string]$Line)
    try {
        return ($Line | ConvertFrom-Json -AsHashtable)
    } catch {
        $preview = if ($Line.Length -gt 200) { $Line.Substring(0, 200) + '…' } else { $Line }
        [Console]::Error.WriteLine("ca-bootstrap: failed to parse RPC line from cab-tui ($($_.Exception.Message)); offending bytes: $preview")
        $Script:CABFatalProtocolError = $true
        # Match Drain-CABTuiPending's teardown: complete the inbox so
        # the reader runspace exits, then kill the child process. This
        # is what makes Stop-CABTuiBridge skip its dismiss wait — the
        # process has already exited by the time it runs.
        if ($Script:CABTuiInbox) {
            try { $Script:CABTuiInbox.CompleteAdding() } catch { }
        }
        if ($Script:CABTuiProcess -and -not $Script:CABTuiProcess.HasExited) {
            try { $Script:CABTuiProcess.StandardInput.Close() } catch { }
            try { $Script:CABTuiProcess.Kill() } catch { }
        }
        return $null
    }
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
        } catch { }

        # docs/rpc-protocol.md: after `done`, the TUI may keep running so
        # the user can review the transcript. The orchestrator therefore
        # waits for the user to dismiss (press q in the TUI) instead of
        # forcing EOF on stdin and killing within seconds. The wait is
        # bounded so headless / CI runs don't hang forever — set
        # CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT in seconds (default 300, i.e.
        # 5 minutes; 0 means wait indefinitely).
        $timeoutSec = 300
        if ($env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT) {
            $parsed = 0
            if ([int]::TryParse($env:CA_BOOTSTRAP_TUI_DISMISS_TIMEOUT, [ref]$parsed)) {
                $timeoutSec = $parsed
            }
        }
        $exited = $false
        if ($timeoutSec -le 0) {
            $Script:CABTuiProcess.WaitForExit()
            $exited = $true
        } else {
            $exited = $Script:CABTuiProcess.WaitForExit($timeoutSec * 1000)
        }
        if (-not $exited) {
            # Final safety net: the user walked away or the TUI hung.
            # Close stdin first so the consumer task drains cleanly,
            # then kill if it still hasn't exited.
            try { $Script:CABTuiProcess.StandardInput.Close() } catch { }
            if (-not $Script:CABTuiProcess.WaitForExit(2000)) {
                try { $Script:CABTuiProcess.Kill() } catch { }
            }
        }
    }
    # Tear down the background reader. Closing StandardOutput on Dispose
    # is enough to make ReadLine() return null and exit the loop, which
    # in turn calls CompleteAdding() and lets the runspace finish.
    if ($Script:CABTuiInbox) {
        try { $Script:CABTuiInbox.CompleteAdding() } catch { }
    }
    if ($Script:CABTuiReaderInstance) {
        try {
            $Script:CABTuiReaderInstance.EndInvoke($Script:CABTuiReaderHandle)
        } catch { }
        try { $Script:CABTuiReaderInstance.Dispose() } catch { }
    }
    if ($Script:CABTuiInbox) {
        try { $Script:CABTuiInbox.Dispose() } catch { }
    }
    $Script:CABTuiInbox = $null
    $Script:CABTuiReaderInstance = $null
    $Script:CABTuiReaderHandle = $null
    $Script:CABTuiProcess = $null
    $Script:CABTuiHandshakeComplete = $false
}

# Functions exported automatically when this file is dot-sourced.
