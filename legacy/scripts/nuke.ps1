#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
ca-bootstrap full-purge wrapper (Windows-native peer of scripts/nuke.sh).

.DESCRIPTION
Reverses every journaled action (workspace folders, repos, git identity,
plugin link), then removes the entire ca-bootstrap state directory
(default $HOME\.ca-bootstrap; honours $env:CA_BOOTSTRAP_STATE).

Tools (.NET 10, Node 20, Python 3.12, Docker, VS Code, Claude Code,
Copilot CLI, ...) are NOT uninstalled by default — those are typically
shared with other projects on the machine, so removing them is opt-in
via -IncludeTools.

.PARAMETER IncludeTools
Also pass -IncludeTools to the inner undo so manifest tools get uninstalled
too. Destructive across the whole machine; default off.

.PARAMETER Confirm
Skip the interactive YES prompt. Required for unattended/scripted use.

.PARAMETER DryRun
Print the plan and the underlying commands but do not execute them.

.NOTES
Exit codes:
  0  success (or DryRun completed)
  1  user declined confirmation, OR refused unsafe STATE_DIR
  7  propagated from the inner undo when a destructive op fails mid-flight
     (commands/undo.ps1 returns 7 in that case). The state-dir removal step
     is skipped on non-zero undo so a retry can resume.
#>

[CmdletBinding()]
param(
    [switch]$IncludeTools,
    [switch]$Confirm,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $script:RepoRoot

$script:Pwsh = if ($env:PWSH) { $env:PWSH } else { 'pwsh' }

function Write-Bad  { param([string]$Msg) Write-Host "ERROR: $Msg" -ForegroundColor Red }
function Write-Ok   { param([string]$Msg) Write-Host "OK $Msg"     -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "-> $Msg"     -ForegroundColor Blue }
function Write-Warn2 { param([string]$Msg) Write-Host "WARNING: $Msg" -ForegroundColor Yellow }

function Stop-WithError {
    param([string]$Msg, [int]$Code = 1)
    Write-Bad $Msg
    exit $Code
}

# Resolve PWSH on PATH. Get-Command without -ErrorAction would write to the
# error stream and exit under ErrorActionPreference=Stop, so we probe silently
# and emit our own friendlier message.
if (-not (Get-Command $script:Pwsh -ErrorAction SilentlyContinue)) {
    Stop-WithError "$($script:Pwsh) not found on PATH"
}

# ---------------------------------------------------------------------------
# STATE_DIR resolution + validation
# ---------------------------------------------------------------------------
#
# IMPORTANT: only fall back to $HOME\.ca-bootstrap when the env var is
# genuinely *not set*. An explicitly-empty CA_BOOTSTRAP_STATE='' must reach
# the safety guard below so tests that assert "empty is refused" can fire.
# (Mirror of the bash ${VAR-default} vs ${VAR:-default} distinction.)
if ($null -eq (Get-Item env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue)) {
    $stateDir = Join-Path $HOME '.ca-bootstrap'
}
else {
    $stateDir = $env:CA_BOOTSTRAP_STATE
}

# Normalize path separators so endsWith / equality checks behave predictably.
function Convert-PathToCanonical {
    param([string]$P)
    if ([string]::IsNullOrEmpty($P)) { return $P }
    # Replace forward slashes with backslashes on Windows. On non-Windows
    # the script should still run (the codebase supports macOS/Linux pwsh),
    # so use the platform's directory separator rather than hardcoding '\'.
    $sep = [IO.Path]::DirectorySeparatorChar
    $alt = [IO.Path]::AltDirectorySeparatorChar
    return $P.Replace($alt, $sep).TrimEnd($sep)
}

$stateDirNormalized = Convert-PathToCanonical $stateDir
$homeNormalized     = Convert-PathToCanonical $HOME

# Validate STATE_DIR before any confirmation prompt. A misconfigured
# CA_BOOTSTRAP_STATE (empty, root, or $HOME by accident) would otherwise
# turn a confirmed YES into a Remove-Item -Recurse disaster. The contract
# is narrow: ca-bootstrap state dirs end in '.ca-bootstrap'.
if ([string]::IsNullOrEmpty($stateDirNormalized)) {
    Stop-WithError 'CA_BOOTSTRAP_STATE is empty — refuse to nuke.'
}

# On Windows the drive root is e.g. 'C:' or 'C:\'. Refuse both forms,
# plus the POSIX root '/'. After Convert-PathToCanonical they're trimmed,
# so check the bare drive-letter shape explicitly.
if ($stateDirNormalized -eq '/' -or
    $stateDirNormalized -eq '\' -or
    $stateDirNormalized -match '^[A-Za-z]:$' -or
    $stateDirNormalized -match '^[A-Za-z]:\\$') {
    Stop-WithError "CA_BOOTSTRAP_STATE='$stateDir' is a filesystem root — refuse to nuke."
}

if ($stateDirNormalized -eq $homeNormalized) {
    Stop-WithError "CA_BOOTSTRAP_STATE='$stateDir' equals `$HOME — refuse to nuke the home directory."
}

# Absolute / fully-qualified check. IsPathFullyQualified rejects drive-
# relative paths like '\foo' on Windows (which IsPathRooted accepts) —
# we want the stricter check so a typo can't hand us a near-root rm.
if (-not [IO.Path]::IsPathFullyQualified($stateDirNormalized)) {
    Stop-WithError "CA_BOOTSTRAP_STATE='$stateDir' is not absolute — refuse to nuke."
}

if (-not ($stateDirNormalized.ToLowerInvariant().EndsWith('.ca-bootstrap'))) {
    Stop-WithError "CA_BOOTSTRAP_STATE='$stateDir' does not end in '.ca-bootstrap' — refuse to nuke. Rename your state dir or unset the variable."
}

# Depth check: refuse paths with fewer than 3 components. So
# `C:\Users\peter\.ca-bootstrap` (4 components) passes, `C:\.ca-bootstrap`
# (2 non-empty components) is refused. Catches the case where $HOME is
# somehow empty and the default resolves to literally `\.ca-bootstrap`.
$sep = [IO.Path]::DirectorySeparatorChar
$components = $stateDirNormalized.Split($sep) | Where-Object { -not [string]::IsNullOrEmpty($_) }
if ($components.Count -lt 3) {
    Stop-WithError "CA_BOOTSTRAP_STATE='$stateDir' has too few path components (need >=3, got $($components.Count)) — refuse to nuke."
}

# ---------------------------------------------------------------------------
# Build the undo argument list
# ---------------------------------------------------------------------------
#
# We do NOT pass -Unattended: that flag requires -ConfigFile + -Force, and
# we don't want to ship a fake answer file just to suppress prompts. -Force
# is the bypass we actually need — the user already typed YES to nuke.
$undoArgs = @('undo', '-All', '-IncludeFolders', '-Force')
if ($IncludeTools) { $undoArgs += '-IncludeTools' }

# ---------------------------------------------------------------------------
# Plan + confirmation
# ---------------------------------------------------------------------------

Write-Host 'ca-bootstrap nuke — full-purge plan:' -ForegroundColor Blue
Write-Host "  * Reverse every journaled action via ca-bootstrap.ps1 $($undoArgs -join ' ')"
Write-Host '      (workspace folders, cloned repos, git includeIf, plugin link)'
if ($IncludeTools) {
    Write-Host '  * Uninstall manifest tools (.NET 10, Node 20, Python 3.12, Docker, VS Code, Claude Code, Copilot CLI, ...)'
    Write-Warn2 '      this affects every project on this machine, not just ChannelAssist.'
}
Write-Host "  * Remove the ca-bootstrap state directory: $stateDir"
Write-Host '      (journal, runs/, last-run.log, cache, lock dir)'
Write-Host ''

if ($Confirm) {
    Write-Info 'Confirm=true — skipping interactive prompt.'
}
elseif ($DryRun) {
    Write-Info 'DryRun=true — skipping interactive prompt (no mutations would happen anyway).'
}
else {
    $reply = Read-Host 'Type YES (uppercase) to proceed, anything else to abort'
    if ($reply -ne 'YES') {
        Write-Warn2 "Aborted (received: '$reply')."
        exit 1
    }
}

if ($DryRun) {
    Write-Info "DryRun: would run: $($script:Pwsh) -NoLogo -File .\ca-bootstrap.ps1 $($undoArgs -join ' ')"
    Write-Info "DryRun: would run: Remove-Item -Recurse -Force '$stateDir'"
    Write-Ok 'DryRun: nuke plan validated (no mutations).'
    exit 0
}

# ---------------------------------------------------------------------------
# Reverse journaled actions
# ---------------------------------------------------------------------------
#
# "Nothing to undo" is exit 0 in commands/undo.ps1, so a non-zero return is
# a real failure: user quit (1), mid-operation breakage (7), or safety
# refusal (8). Propagate the code and stop — leaving the state dir intact
# lets the user retry without losing whatever partial reversal happened.

Write-Info 'Reversing journaled actions...'
& $script:Pwsh -NoLogo -File (Join-Path $script:RepoRoot 'ca-bootstrap.ps1') @undoArgs
$undoRc = $LASTEXITCODE
if ($undoRc -ne 0) {
    Write-Warn2 "undo exited $undoRc — leaving state dir in place so you can retry."
    exit $undoRc
}
Write-Ok 'undo completed.'

# ---------------------------------------------------------------------------
# Remove state dir
# ---------------------------------------------------------------------------
# Even if undo missed something (e.g. a manually-created file in
# ~/.ca-bootstrap/runs/), this wipes the lot.

if (Test-Path $stateDir) {
    Write-Info "Removing $stateDir..."
    Remove-Item -Recurse -Force $stateDir
    Write-Ok "$stateDir removed."
}
else {
    Write-Info "$stateDir not present — already clean."
}

Write-Ok 'ca-bootstrap nuke complete.'
Write-Host ''
Write-Host 'Next steps to start fresh:'
Write-Host "  * ./make.ps1 setup     # rerun the wizard"      -ForegroundColor Blue
Write-Host "  * ./make.ps1 doctor    # verify a clean slate"  -ForegroundColor Blue
