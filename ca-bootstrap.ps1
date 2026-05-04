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
    [ValidateSet('setup','doctor','repair','undo','help','--help','-h','version','--version')]
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
$Script:CABootstrapVersion = '1.3.0'

# Resolve the repo root (where this script lives), not the user's cwd.
$Script:CABootstrapRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Honour --no-color before importing the UI module.
if ($NoColor -or $env:NO_COLOR) { $env:CA_BOOTSTRAP_NO_COLOR = '1' }

# Override transcript path if provided.
if ($LogPath) { $env:CA_BOOTSTRAP_STATE = (Split-Path -Parent (Resolve-Path $LogPath -ErrorAction SilentlyContinue) ?? $LogPath) }

# Dot-source libraries into the orchestrator's scope.
$libs = @('ui.ps1','prompts.ps1','journal.ps1','yaml.ps1','git-ops.ps1','platform.ps1','tools.ps1','answers.ps1') | ForEach-Object { Join-Path $Script:CABootstrapRoot "lib/$_" }
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

# Banner + session start. Suppressed when --json or --quiet is set so the
# JSON / one-line-summary output isn't polluted with banner text on stdout.
$silent = $Json -or $Quiet
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
    if ($silent) {
        # Still need the journal session, but skip the on-screen banner.
        Read-CABJournal | Out-Null
        $Script:CABootstrapSessionId = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
    } else {
        Start-CABSession -Command $Command -Version $Script:CABootstrapVersion
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
    param($sender, $eventArgs)
    $eventArgs.Cancel = $true   # don't terminate; let us handle it
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
    if ($silent) {
        Save-CABJournal
    } else {
        Stop-CABSession -ExitCode $exitCode
    }
}

exit $exitCode
