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
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Script:CABootstrapVersion = '0.1.0-phase1'

# Resolve the repo root (where this script lives), not the user's cwd.
$Script:CABootstrapRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Honour --no-color before importing the UI module.
if ($NoColor -or $env:NO_COLOR) { $env:CA_BOOTSTRAP_NO_COLOR = '1' }

# Override transcript path if provided.
if ($LogPath) { $env:CA_BOOTSTRAP_STATE = (Split-Path -Parent (Resolve-Path $LogPath -ErrorAction SilentlyContinue) ?? $LogPath) }

# Dot-source libraries into the orchestrator's scope.
$libs = @('ui.ps1','prompts.ps1','journal.ps1') | ForEach-Object { Join-Path $Script:CABootstrapRoot "lib/$_" }
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
    # Phase 1: we read but don't yet parse YAML. Phase 11 wires powershell-yaml.
    Set-CABPromptMode -Unattended $true -Answers @{}
    Write-CABColor Yellow "  (Unattended mode enabled. Phase 1 does not yet parse $ConfigFile — flag handling is wired but YAML parsing comes in phase 11.)"
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
}

# Banner + session start.
Write-CABBanner -Version $Script:CABootstrapVersion
Start-CABSession -Command $Command -Version $Script:CABootstrapVersion

$exitCode = 0
try {
    switch ($Command) {
        'setup'  {
            . (Join-Path $Script:CABootstrapRoot 'commands/setup.ps1')
            $exitCode = Invoke-CABCommandSetup  -Context $context
        }
        'doctor' {
            . (Join-Path $Script:CABootstrapRoot 'commands/doctor.ps1')
            $exitCode = Invoke-CABCommandDoctor -Context $context
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
    Stop-CABSession -ExitCode $exitCode
}

exit $exitCode
