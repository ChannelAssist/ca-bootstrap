#requires -Version 7.0
# lib/journal.ps1 — read/write the action journal.
#
# v1 phase 1 stub: just enough surface to record session start/end and
# append simple action entries. Reconstruction logic comes in phase 7.

$Script:CABootstrapStateDir   = if ($env:CA_BOOTSTRAP_STATE) { $env:CA_BOOTSTRAP_STATE } else { Join-Path $HOME '.ca-bootstrap' }
$Script:CABootstrapJournalPath = Join-Path $Script:CABootstrapStateDir 'journal.yaml'
$Script:CABootstrapTranscript  = Join-Path $Script:CABootstrapStateDir 'last-run.log'
$Script:CABootstrapSessionId   = $null

function Initialize-CABJournal {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $Script:CABootstrapStateDir)) {
        [void](New-Item -ItemType Directory -Path $Script:CABootstrapStateDir -Force)
    }
    if (-not (Test-Path $Script:CABootstrapJournalPath)) {
        $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { 'unknown' }
        $initial = @"
schema_version: 1
host:
  os: $os
  user: $env:USER$env:USERNAME
  hostname: $([System.Net.Dns]::GetHostName())
sessions: []
"@
        $initial | Set-Content -Path $Script:CABootstrapJournalPath -NoNewline:$false
    }
}

function Start-CABSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('setup','doctor','repair','undo')] [string]$Command,
        [Parameter(Mandatory)] [string]$Version,
        [string]$WorkspacePath
    )
    Initialize-CABJournal
    $Script:CABootstrapSessionId = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')

    # Rotate prior transcript if present.
    if (Test-Path $Script:CABootstrapTranscript) {
        $runsDir = Join-Path $Script:CABootstrapStateDir 'runs'
        if (-not (Test-Path $runsDir)) { [void](New-Item -ItemType Directory -Path $runsDir -Force) }
        $rotated = Join-Path $runsDir ((Get-Item $Script:CABootstrapTranscript).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH-mm-ssZ') + '.log')
        Move-Item -Path $Script:CABootstrapTranscript -Destination $rotated -Force
        # Keep only the 10 most recent rotated runs.
        Get-ChildItem $runsDir -Filter '*.log' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Start-Transcript -Path $Script:CABootstrapTranscript -Force | Out-Null

    Write-Host ''
    Write-Host "[ca-bootstrap session $Script:CABootstrapSessionId]"
    Write-Host "  command : $Command"
    Write-Host "  version : $Version"
    Write-Host "  os      : $(if ($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'})"
    Write-Host "  pwsh    : $($PSVersionTable.PSVersion)"
    if ($WorkspacePath) { Write-Host "  ws      : $WorkspacePath" }
    Write-Host ''
}

function Stop-CABSession {
    [CmdletBinding()]
    param([int]$ExitCode = 0)
    Write-Host ''
    Write-Host "[ca-bootstrap session $Script:CABootstrapSessionId end — exit $ExitCode]"
    try { Stop-Transcript | Out-Null } catch { }
}

function Get-CABTranscriptPath { $Script:CABootstrapTranscript }
function Get-CABJournalPath    { $Script:CABootstrapJournalPath }
function Get-CABSessionId      { $Script:CABootstrapSessionId }

# Functions exported automatically when this file is dot-sourced.
