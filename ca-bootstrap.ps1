#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
ca-bootstrap orchestrator. Dispatches to one of: setup, doctor, repair, undo.

.DESCRIPTION
This is the multi-command entry point. The bootstrap.sh / bootstrap.ps1
one-liners hand control here after ensuring pwsh and git are available.

Phase 1 implements the orchestrator skeleton, the welcome step, transcript
logging, and command dispatch. Subsequent phases fill in the detection,
install, and reversal logic for each step.

.EXAMPLE
./ca-bootstrap.ps1                   # default: setup
./ca-bootstrap.ps1 setup
./ca-bootstrap.ps1 doctor
./ca-bootstrap.ps1 repair --all
./ca-bootstrap.ps1 undo

.EXAMPLE
./ca-bootstrap.ps1 setup -Unattended -ConfigFile answers.yaml
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup','doctor','repair','undo','manifest-drift','manifest-edit','help','--help','-h','version','--version')]
    [string]$Command = 'setup',

    [switch]$Unattended,
    [string]$ConfigFile,
    [switch]$WhatIfMode,        # avoid clashing with PS built-in -WhatIf
    [string]$LogPath,
    [switch]$NoColor,

    # repair / undo flags
    [switch]$All,
    [string]$Target,
    [switch]$IncludeTools,
    [switch]$IncludeFolders,
    [switch]$Force,
    [switch]$AutoConfirm,

    # doctor flags
    [switch]$Json,
    [switch]$Summary,
    [switch]$Quiet,

    # break-glass: forcibly remove a stale lock before running
    [switch]$ForceUnlock
)

$ErrorActionPreference = 'Stop'
$Script:CABootstrapVersion = '1.9.0'

# Resolve the repo root (where this script lives), not the user's cwd.
$Script:CABootstrapRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Honour --no-color before importing the UI module.
if ($NoColor -or $env:NO_COLOR) { $env:CA_BOOTSTRAP_NO_COLOR = '1' }

# Override transcript path if provided.
if ($LogPath) { $env:CA_BOOTSTRAP_STATE = (Split-Path -Parent (Resolve-Path $LogPath -ErrorAction SilentlyContinue) ?? $LogPath) }

# Dot-source libraries into the orchestrator's scope.
$libs = @('ui.ps1','prompts.ps1','journal.ps1','yaml.ps1','git-ops.ps1','platform.ps1','tools.ps1','answers.ps1','folders.ps1') | ForEach-Object { Join-Path $Script:CABootstrapRoot "lib/$_" }
foreach ($lib in $libs) {
    if (-not (Test-Path $lib)) { Write-Error "Required library missing: $lib"; exit 99 }
    . $lib
}

# Handle help/version short-circuits.
if ($Command -in @('help','--help','-h')) {
    Write-CABBanner -Version $Script:CABootstrapVersion
    Get-Content (Join-Path $Script:CABootstrapRoot 'docs/commands.md') -ErrorAction SilentlyContinue |
        Select-Object -First 80 | Write-Host
    exit 0
}
if ($Command -in @('version','--version')) {
    Write-Host "ca-bootstrap $Script:CABootstrapVersion"
    exit 0
}

# Configure unattended mode.
if ($Unattended) {
    if (-not $ConfigFile) {
        Write-CABColor Red 'ERROR: -Unattended requires -ConfigFile <path>.'
        exit 1
    }
    if (-not (Test-Path $ConfigFile)) {
        Write-CABColor Red "ERROR: ConfigFile not found: $ConfigFile"
        exit 1
    }
    if ($Command -eq 'undo' -and -not $Force) {
        Write-CABColor Red 'ERROR: `undo -Unattended` requires -Force (destructive).'
        exit 1
    }
    try {
        $rawAnswers = Read-CABAnswersFile -Path $ConfigFile
        $flatAnswers = Convert-CABAnswersToFlat -Answers $rawAnswers
        Set-CABPromptMode -Unattended $true -Answers $flatAnswers
        Write-CABColor DarkGray "  (Unattended mode: $($flatAnswers.Count) answer keys loaded from $ConfigFile.)"
    } catch {
        Write-CABColor Red "ERROR loading answers file: $($_.Exception.Message)"
        exit 1
    }
} else {
    Set-CABPromptMode -Unattended $false -Answers @{}
}

# Build session context.
$context = @{
    RepoRoot     = $Script:CABootstrapRoot
    Version      = $Script:CABootstrapVersion
    Command      = $Command
    Unattended   = [bool]$Unattended
    ConfigFile   = $ConfigFile
    WhatIfMode   = [bool]$WhatIfMode
    All          = [bool]$All
    Target       = $Target
    IncludeTools = [bool]$IncludeTools
    IncludeFolders = [bool]$IncludeFolders
    Force        = [bool]$Force
    AutoConfirm  = [bool]$AutoConfirm
    Json         = [bool]$Json
    Summary      = [bool]$Summary
    Quiet        = [bool]$Quiet
    # Test-mode seam (see TEST_PLAN.md §8.1). Picked up by every step
    # that would otherwise shell out to a real tool / browser / sudo.
    TestMode     = [bool]$env:CA_BOOTSTRAP_TEST_MODE
    TestGhUser   = $env:CA_BOOTSTRAP_TEST_GH_USER
    TestToolsOk  = if ($env:CA_BOOTSTRAP_TEST_TOOLS_OK) { $env:CA_BOOTSTRAP_TEST_TOOLS_OK -split ',' } else { @() }
    TestNoInstall = [bool]$env:CA_BOOTSTRAP_TEST_NO_INSTALL
    TestReposFile = $env:CA_BOOTSTRAP_TEST_REPOS_FILE
}

# Banner suppression and session-start skipping are two separate gates:
#
#   $silent       = $Json -or $Quiet      → also suppresses the banner +
#                                            -not-strictly-silent prints,
#                                            so stdout stays clean for the
#                                            JSON / one-line summary.
#   $skipSession  = $silent -and          → ALSO skips Start-CABSession.
#                   $readOnlyCommand        Only the read-only commands
#                                            (doctor, manifest-drift) may
#                                            skip it; mutating commands
#                                            (setup, repair, undo,
#                                            manifest-edit) must always
#                                            pair Add-CABJournalEntry with
#                                            a Start-CABSession upstream
#                                            or the throw fires mid-run
#                                            and the audit trail is lost.
#                                            See the static caller audit
#                                            in tests/lib/journal-session-
#                                            required.tests.ps1.
$readOnlyCommand = $Command -in @('doctor','manifest-drift')
$silent = $Json -or $Quiet
$skipSession = $silent -and $readOnlyCommand
if ($context.TestMode -and -not $silent) {
    Write-CABColor Yellow '  ⚠ TEST MODE — gh auth, tool installs, and remote clones may be stubbed.'
}
if (-not $silent) {
    Write-CABBanner -Version $Script:CABootstrapVersion
}
# Honor --force-unlock by clearing any existing lockfile before the
# session tries to acquire one. Useful when a previous run crashed.
if ($ForceUnlock) {
    $stateDir = if ($env:CA_BOOTSTRAP_STATE) { $env:CA_BOOTSTRAP_STATE } else { Join-Path $HOME '.ca-bootstrap' }
    foreach ($p in @((Join-Path $stateDir 'session.lock.d'), (Join-Path $stateDir 'session.lock'))) {
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
            if (-not $silent) { Write-CABColor Yellow "  ⚠ -ForceUnlock: removed $p" }
        }
    }
}

try {
    if ($skipSession) {
        # JSON / quiet modes for the read-only commands avoid stdout noise.
        # manifest-drift is read-only, so its silent path can skip journal
        # I/O entirely; doctor still reads the journal to cross-check
        # detected state against recorded actions.
        if ($Command -ne 'manifest-drift') {
            Read-CABJournal | Out-Null
        }
        $Script:CABootstrapSessionId = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
    } else {
        # -Quiet:$silent so --json / --quiet mutating commands still
        # get a real session (audit trail) without the banner output
        # polluting stdout. Locks, journal I/O, and transcript rotation
        # all still happen — only the visible header is suppressed.
        Start-CABSession -Command $Command -Version $Script:CABootstrapVersion -Quiet:$silent
    }
}
catch [CABSessionLockedException] {
    Write-CABColor Red ''
    Write-CABColor Red '  Another ca-bootstrap session is already running.'
    Write-Host  "    Lock file: $($_.Exception.LockPath)"
    if ($_.Exception.Holder -and $_.Exception.Holder.pid) {
        Write-Host  "    Holder   : pid=$($_.Exception.Holder.pid) started=$($_.Exception.Holder.started)"
    }
    Write-Host ''
    Write-Host  '  If the previous run crashed and the lock is stale, run:'
    Write-CABColor Cyan '      ca-bootstrap.ps1 ' "$Command -ForceUnlock"
    Write-Host  '  Otherwise wait for the other session to finish.'
    Write-Host ''
    exit 5
}

$Script:CABQuitRequested = $false

# Ctrl+C trap. PowerShell's [Console]::CancelKeyPress fires on Ctrl-C
# before the process is terminated. We set a flag the orchestrator
# checks between steps and on prompt return, so the user gets the same
# rollback offer they'd get by typing 'q'.
$null = [Console]::add_CancelKeyPress({
    # The CancelKeyPress delegate signature is (object sender,
    # ConsoleCancelEventArgs e). We only need eArgs but the binding
    # requires both positional params. Reading $src once anchors PSSA's
    # "used" detection without changing behavior.
    param($src, $eArgs)
    $null = $src
    $eArgs.Cancel = $true   # don't terminate; let us handle it
    $Script:CABQuitRequested = $true
    Write-Host ''
    Write-CABColor Yellow '  ⚠ Ctrl+C — quitting after the current step. Press Ctrl+C again to force-exit.'
})

$exitCode = 0
try {
    switch ($Command) {
        'setup'  {
            . (Join-Path $Script:CABootstrapRoot 'commands/setup.ps1')
            $exitCode = Invoke-CABCommandSetup  -Context $context
        }
        'doctor' {
            . (Join-Path $Script:CABootstrapRoot 'commands/doctor.ps1')
            if ($Json) {
                # JSON mode: function writes the JSON to the success
                # stream (which is this script's stdout), and the exit
                # code is communicated via $Script:CABDoctorExitCode
                # so we don't pollute the JSON with a trailing int.
                $Script:CABDoctorExitCode = $null
                Invoke-CABCommandDoctor -Context $context
                $exitCode = [int]$Script:CABDoctorExitCode
            } else {
                $exitCode = [int](Invoke-CABCommandDoctor -Context $context)
            }
        }
        'repair' {
            . (Join-Path $Script:CABootstrapRoot 'commands/repair.ps1')
            $exitCode = Invoke-CABCommandRepair -Context $context -All:$All -Target $Target
        }
        'undo'   {
            . (Join-Path $Script:CABootstrapRoot 'commands/undo.ps1')
            $exitCode = Invoke-CABCommandUndo   -Context $context -Target $Target -IncludeTools:$IncludeTools -IncludeFolders:$IncludeFolders -Force:$Force
        }
        'manifest-drift' {
            . (Join-Path $Script:CABootstrapRoot 'commands/manifest-drift.ps1')
            $r = Invoke-CABCommandManifestDrift -Context $context -Json:$Json
            # In sync → 0; drift detected → 8; operational failures keep
            # their own non-8 exit code so callers can distinguish them.
            $exitCode = if ($null -ne $r.exit_code) { [int]$r.exit_code } elseif ($r.ok) { 0 } else { 8 }
        }
        'manifest-edit' {
            . (Join-Path $Script:CABootstrapRoot 'commands/manifest-edit.ps1')
            # manifest-edit shares the manifest-drift Get-CABSuggestedGroup
            # heuristic + Read-CABManifest -Quiet seam.
            . (Join-Path $Script:CABootstrapRoot 'commands/manifest-drift.ps1')
            $r = Invoke-CABCommandManifestEdit -Context $context
            $exitCode = if ($null -ne $r.exit_code) { [int]$r.exit_code } elseif ($r.ok) { 0 } else { 8 }
        }
    }
}
catch {
    Write-CABColor Red ''
    Write-CABColor Red "  Unexpected error: $($_.Exception.Message)"
    Write-CABColor DarkGray "  Transcript: $(Get-CABTranscriptPath)"
    Write-CABColor DarkGray "  $($_.ScriptStackTrace)"
    $exitCode = 99
}
finally {
    if ($skipSession) {
        if ($Command -ne 'manifest-drift') {
            Save-CABJournal
        }
    } else {
        # -Quiet:$silent matches the Start-CABSession call upstream so
        # --json / --quiet mutating commands stay clean on stdout for
        # the full lifecycle. The session-end banner is suppressed;
        # journal save, transcript stop, and lock release still run.
        Stop-CABSession -ExitCode $exitCode -Quiet:$silent
    }
}

exit $exitCode
