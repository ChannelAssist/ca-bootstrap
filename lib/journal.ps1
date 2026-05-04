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
    # Ensure the state directory exists. Save-CABJournal is the sole
    # writer of the journal file itself — initial header included.
    if (-not (Test-Path $Script:CABootstrapStateDir)) {
        [void](New-Item -ItemType Directory -Path $Script:CABootstrapStateDir -Force)
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

# Add-CABJournalEntry — append an action record to the current session.
#   Each step calls this from its Invoke function after a successful action.
#   Phase 1 stores entries to the in-memory list; full YAML serialization
#   lands in phase 7 along with the recovery / reconstruction logic.
function Add-CABJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Action,
        [bool]$Reversible = $true,
        [hashtable]$Data = @{}
    )
    if (-not $Script:CABJournalSession) {
        $Script:CABJournalSession = @{
            id      = $Script:CABootstrapSessionId
            actions = New-Object System.Collections.Generic.List[hashtable]
        }
    }
    $entry = @{
        id         = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
        step       = $Step
        action     = $Action
        reversible = $Reversible
        undone     = $false
    }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }
    $Script:CABJournalSession.actions.Add($entry)
    return $entry
}

function Get-CABJournalEntries {
    [CmdletBinding()]
    param([string]$Action)
    if (-not $Script:CABJournalSession) { return @() }
    if ($Action) { return $Script:CABJournalSession.actions | Where-Object { $_.action -eq $Action } }
    return $Script:CABJournalSession.actions
}

# Save-CABJournal — persist the current session to disk as YAML.
#   Phase 1 writes a simple flat structure; phase 7 will add cross-session
#   merge / reconstruction.
function Save-CABJournal {
    [CmdletBinding()]
    param()
    if (-not $Script:CABJournalSession -or $Script:CABJournalSession.actions.Count -eq 0) { return }
    Initialize-CABJournal

    # Read existing journal (if any) and append this session.
    $existingLines = if (Test-Path $Script:CABootstrapJournalPath) {
        Get-Content -Path $Script:CABootstrapJournalPath
    } else { @() }

    $sb = [System.Text.StringBuilder]::new()
    if ($existingLines.Count -eq 0) {
        $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { 'unknown' }
        $userName = if ($env:USER) { $env:USER } else { $env:USERNAME }
        [void]$sb.AppendLine('schema_version: 1')
        [void]$sb.AppendLine('host:')
        [void]$sb.AppendLine("  os: $os")
        [void]$sb.AppendLine("  user: $userName")
        [void]$sb.AppendLine("  hostname: $([System.Net.Dns]::GetHostName())")
        [void]$sb.AppendLine('sessions:')
    } else {
        # Re-emit existing content (already has sessions: line).
        foreach ($l in $existingLines) { [void]$sb.AppendLine($l) }
    }

    [void]$sb.AppendLine("  - id: $($Script:CABJournalSession.id)")
    [void]$sb.AppendLine("    actions:")
    foreach ($action in $Script:CABJournalSession.actions) {
        [void]$sb.AppendLine("      - id: $($action.id)")
        [void]$sb.AppendLine("        step: $($action.step)")
        [void]$sb.AppendLine("        action: $($action.action)")
        [void]$sb.AppendLine("        reversible: $($action.reversible.ToString().ToLower())")
        [void]$sb.AppendLine("        undone: false")
        foreach ($k in $action.Keys) {
            if ($k -in @('id','step','action','reversible','undone')) { continue }
            $v = $action[$k]
            $vStr = if ($v -is [bool]) { $v.ToString().ToLower() } else { """$v""" }
            [void]$sb.AppendLine("        $($k): $vStr")
        }
    }

    Set-Content -Path $Script:CABootstrapJournalPath -Value $sb.ToString().TrimEnd() -NoNewline:$false
}

# Functions exported automatically when this file is dot-sourced.
