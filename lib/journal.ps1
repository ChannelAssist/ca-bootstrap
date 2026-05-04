#requires -Version 7.0
# lib/journal.ps1 — action journal: read, write, append, query, recover.
#
# Phase 7 implementation. The journal is the source of truth for what
# ca-bootstrap has done on this machine. doctor (phase 8), repair (phase 9),
# and undo (phase 10) all consume it via Get-CABJournalEntries and update
# it via Mark-CABEntryUndone.
#
# File:    ~/.ca-bootstrap/journal.yaml
# Schema:  see docs/action-journal.md
#
# Threading: ca-bootstrap is single-threaded; this code makes no
# accommodation for concurrent writers.

$Script:CABootstrapStateDir    = if ($env:CA_BOOTSTRAP_STATE) { $env:CA_BOOTSTRAP_STATE } else { Join-Path $HOME '.ca-bootstrap' }
$Script:CABootstrapJournalPath = Join-Path $Script:CABootstrapStateDir 'journal.yaml'
$Script:CABootstrapTranscript  = Join-Path $Script:CABootstrapStateDir 'last-run.log'
$Script:CABootstrapSessionId   = $null
$Script:CABJournalState        = $null   # full in-memory representation of the journal

# ---------------------------------------------------------------------------
# Path accessors
# ---------------------------------------------------------------------------

function Get-CABTranscriptPath { $Script:CABootstrapTranscript }
function Get-CABJournalPath    { $Script:CABootstrapJournalPath }
function Get-CABSessionId      { $Script:CABootstrapSessionId }
function Get-CABStateDir       { $Script:CABootstrapStateDir }

# ---------------------------------------------------------------------------
# State directory + file I/O
# ---------------------------------------------------------------------------

function Initialize-CABJournal {
    [CmdletBinding()]
    param()
    if (-not (Test-Path $Script:CABootstrapStateDir)) {
        [void](New-Item -ItemType Directory -Path $Script:CABootstrapStateDir -Force)
    }
}

function New-CABJournalSkeleton {
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { 'unknown' }
    $userName = if ($env:USER) { $env:USER } else { $env:USERNAME }
    return [ordered]@{
        schema_version = 1
        host           = [ordered]@{
            os       = $os
            user     = $userName
            hostname = [System.Net.Dns]::GetHostName()
        }
        sessions       = @()
    }
}

# Read-CABJournal — load the journal file into $Script:CABJournalState.
# If the file is missing or empty, creates a fresh skeleton in memory but
# does NOT write to disk (that's Save-CABJournal's job).
function Read-CABJournal {
    [CmdletBinding()]
    param()
    Initialize-CABJournal
    if (-not (Test-Path $Script:CABootstrapJournalPath)) {
        $Script:CABJournalState = New-CABJournalSkeleton
        return $Script:CABJournalState
    }
    Initialize-CABYaml
    Import-Module powershell-yaml -DisableNameChecking
    try {
        $raw = Get-Content -Raw -Path $Script:CABootstrapJournalPath
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $Script:CABJournalState = New-CABJournalSkeleton
            return $Script:CABJournalState
        }
        $parsed = ConvertFrom-Yaml $raw
        if (-not $parsed) {
            $Script:CABJournalState = New-CABJournalSkeleton
            return $Script:CABJournalState
        }
        # Normalize: powershell-yaml returns hashtables; we want sessions as
        # an array of hashtables and each session.actions as an array.
        if (-not $parsed.sessions) { $parsed.sessions = @() }
        foreach ($s in @($parsed.sessions)) {
            if (-not $s.actions) { $s.actions = @() }
        }
        $Script:CABJournalState = $parsed
        return $parsed
    } catch {
        Write-CABColor Yellow "  Warning: journal at $Script:CABootstrapJournalPath could not be parsed ($($_.Exception.Message))."
        Write-CABColor Yellow '  Starting with a fresh in-memory skeleton; the file will be backed up before next save.'
        # Back up the corrupt file.
        $backup = "$Script:CABootstrapJournalPath.corrupt-$(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH-mm-ssZ')"
        Move-Item -Path $Script:CABootstrapJournalPath -Destination $backup -Force -ErrorAction SilentlyContinue
        $Script:CABJournalState = New-CABJournalSkeleton
        return $Script:CABJournalState
    }
}

# Save-CABJournal — serialize $Script:CABJournalState to disk.
# Always re-emits the full structure; never appends raw lines.
function Save-CABJournal {
    [CmdletBinding()]
    param()
    if (-not $Script:CABJournalState) { return }
    Initialize-CABJournal
    Initialize-CABYaml
    Import-Module powershell-yaml -DisableNameChecking
    $yaml = ConvertTo-Yaml $Script:CABJournalState
    Set-Content -Path $Script:CABootstrapJournalPath -Value $yaml -NoNewline:$false
}

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------

function Start-CABSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('setup','doctor','repair','undo')] [string]$Command,
        [Parameter(Mandatory)] [string]$Version,
        [string]$WorkspacePath
    )
    Read-CABJournal | Out-Null
    $Script:CABootstrapSessionId = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')

    # Ensure host info on the journal reflects this run (in case the user
    # moves the journal between machines or renamed their host).
    $Script:CABJournalState.host = [ordered]@{
        os       = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } elseif ($IsLinux) { 'linux' } else { 'unknown' }
        user     = if ($env:USER) { $env:USER } else { $env:USERNAME }
        hostname = [System.Net.Dns]::GetHostName()
    }

    $newSession = [ordered]@{
        id                   = $Script:CABootstrapSessionId
        command              = $Command
        ca_bootstrap_version = $Version
        actions              = New-Object System.Collections.Generic.List[hashtable]
    }
    if ($WorkspacePath) { $newSession.workspace_path = $WorkspacePath }

    # Append. (Casting because powershell-yaml may give us a raw object.)
    $existing = @()
    if ($Script:CABJournalState.sessions) { $existing = @($Script:CABJournalState.sessions) }
    $Script:CABJournalState.sessions = $existing + @($newSession)

    # Rotate prior transcript if present, then start a new one.
    if (Test-Path $Script:CABootstrapTranscript) {
        $runsDir = Join-Path $Script:CABootstrapStateDir 'runs'
        if (-not (Test-Path $runsDir)) { [void](New-Item -ItemType Directory -Path $runsDir -Force) }
        $rotated = Join-Path $runsDir ((Get-Item $Script:CABootstrapTranscript).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH-mm-ssZ') + '.log')
        Move-Item -Path $Script:CABootstrapTranscript -Destination $rotated -Force
        Get-ChildItem $runsDir -Filter '*.log' | Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Start-Transcript -Path $Script:CABootstrapTranscript -Force | Out-Null

    Write-Host ''
    Write-Host "[ca-bootstrap session $Script:CABootstrapSessionId]"
    Write-Host "  command : $Command"
    Write-Host "  version : $Version"
    Write-Host "  os      : $($Script:CABJournalState.host.os)"
    Write-Host "  pwsh    : $($PSVersionTable.PSVersion)"
    if ($WorkspacePath) { Write-Host "  ws      : $WorkspacePath" }
    Write-Host ''
}

function Stop-CABSession {
    [CmdletBinding()]
    param([int]$ExitCode = 0)
    Save-CABJournal
    Write-Host ''
    Write-Host "[ca-bootstrap session $Script:CABootstrapSessionId end — exit $ExitCode]"
    try { Stop-Transcript | Out-Null } catch { }
}

# Get-CABCurrentSession — returns a reference to the current session
# hashtable so steps can mutate its `actions` list directly.
function Get-CABCurrentSession {
    if (-not $Script:CABJournalState -or -not $Script:CABJournalState.sessions) { return $null }
    $sessions = @($Script:CABJournalState.sessions)
    if ($sessions.Count -eq 0) { return $null }
    return $sessions[-1]
}

# ---------------------------------------------------------------------------
# Action entries
# ---------------------------------------------------------------------------

# Add-CABJournalEntry — append an action record to the current session.
function Add-CABJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Action,
        [bool]$Reversible = $true,
        [hashtable]$Data = @{}
    )
    $session = Get-CABCurrentSession
    if (-not $session) { throw 'No active session — call Start-CABSession first.' }

    $entry = [ordered]@{
        id         = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
        step       = $Step
        action     = $Action
        reversible = $Reversible
        undone     = $false
    }
    foreach ($k in $Data.Keys) { $entry[$k] = $Data[$k] }

    # Convert .actions to a List if powershell-yaml gave us an array.
    if ($session.actions -isnot [System.Collections.Generic.List[hashtable]]) {
        $tmp = New-Object System.Collections.Generic.List[hashtable]
        foreach ($a in @($session.actions)) { $tmp.Add($a) }
        $session.actions = $tmp
    }
    $session.actions.Add($entry)
    return $entry
}

# Get-CABJournalEntries — query across all sessions in the loaded journal.
#   -Action <name>     filter by action type (e.g. 'clone_repo')
#   -Step <id>         filter by step id (e.g. '60-repos')
#   -OnlyOpen          return entries where undone == false (default)
#   -IncludeUndone     also include entries marked undone
#   -SessionCommand    filter by the session.command that produced the entry
function Get-CABJournalEntries {
    [CmdletBinding()]
    param(
        [string]$Action,
        [string]$Step,
        [string]$SessionCommand,
        [switch]$IncludeUndone,
        [switch]$OnlyOpen
    )
    if (-not $Script:CABJournalState) { Read-CABJournal | Out-Null }
    if (-not $Script:CABJournalState.sessions) { return @() }

    $results = New-Object System.Collections.ArrayList
    foreach ($session in @($Script:CABJournalState.sessions)) {
        if ($SessionCommand -and $session.command -ne $SessionCommand) { continue }
        foreach ($entry in @($session.actions)) {
            if ($Action -and $entry.action -ne $Action) { continue }
            if ($Step   -and $entry.step   -ne $Step)   { continue }
            if (-not $IncludeUndone -and $entry.undone) { continue }
            # Mutate in place — we add session pointers but the entry stays
            # the same reference the journal owns.
            if (-not $entry.ContainsKey('_session_id'))      { $entry._session_id      = $session.id }
            if (-not $entry.ContainsKey('_session_command')) { $entry._session_command = $session.command }
            [void]$results.Add($entry)
        }
    }
    # Return the underlying array; callers should wrap with @() if they
    # need a guaranteed-array shape for single-element results.
    return $results.ToArray()
}

# Mark-CABEntryUndone — set undone = true on the original entry, identified
# by its `id` field (timestamps are unique within the journal).
function Mark-CABEntryUndone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EntryId,
        [string]$UndoneAt
    )
    if (-not $Script:CABJournalState) { Read-CABJournal | Out-Null }
    if (-not $UndoneAt) { $UndoneAt = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ') }
    $found = $false
    foreach ($session in @($Script:CABJournalState.sessions)) {
        foreach ($entry in @($session.actions)) {
            if ($entry.id -eq $EntryId) {
                $entry.undone    = $true
                $entry.undone_at = $UndoneAt
                $found = $true
            }
        }
    }
    return $found
}

# ---------------------------------------------------------------------------
# Reconstruction (used by `repair --target journal`)
# ---------------------------------------------------------------------------

# Repair-CABJournal — best-effort rebuild of the journal from on-disk state.
# Walks the workspace and the global gitconfig and emits a synthetic session
# whose entries are tagged reconstructed: true. Pre-state captures (e.g.
# previous_global_email) cannot be recovered.
function Repair-CABJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$Version = 'reconstruction'
    )
    Read-CABJournal | Out-Null

    $sessionId = (Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')
    $session = [ordered]@{
        id                   = $sessionId
        command              = 'repair'
        ca_bootstrap_version = $Version
        workspace_path       = $WorkspacePath
        reconstructed        = $true
        actions              = New-Object System.Collections.Generic.List[hashtable]
    }

    # Workspace folder.
    if (Test-Path $WorkspacePath) {
        $session.actions.Add([ordered]@{
            id                = $sessionId
            step              = '40-workspace'
            action            = 'create_folder'
            reversible        = $true
            undone            = $false
            path              = $WorkspacePath
            is_workspace_root = $true
            reconstructed     = $true
        })
    }

    # Sub-folders.
    foreach ($sub in 'docs','ca-platform','cm-product','ado-legacy') {
        $full = Join-Path $WorkspacePath $sub
        if (Test-Path $full) {
            $session.actions.Add([ordered]@{
                id            = $sessionId
                step          = '50-folders'
                action        = 'create_folder'
                reversible    = $true
                undone        = $false
                path          = $full
                reconstructed = $true
            })
        }
    }

    # Cloned repos (any directory with a .git/ inside the workspace).
    foreach ($sub in 'docs','ca-platform','cm-product','ado-legacy') {
        $full = Join-Path $WorkspacePath $sub
        if (-not (Test-Path $full)) { continue }
        Get-ChildItem -Path $full -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName '.git')) {
                $origin = & git -C $_.FullName remote get-url origin 2>$null
                $repoSlug = if ($origin) { $origin -replace '^https?://github\.com/','' -replace '^git@github\.com:','' -replace '\.git$','' } else { 'unknown' }
                $session.actions.Add([ordered]@{
                    id            = $sessionId
                    step          = '60-repos'
                    action        = 'clone_repo'
                    reversible    = $true
                    undone        = $false
                    repo          = $repoSlug
                    path          = $_.FullName
                    reconstructed = $true
                })
            }
        }
    }

    # Per-folder git identity.
    $globalGitconfig = if ($IsWindows) { Join-Path $env:USERPROFILE '.gitconfig' } else { Join-Path $HOME '.gitconfig' }
    if (Test-Path $globalGitconfig) {
        $content = Get-Content -Raw $globalGitconfig
        $needle = "gitdir:$($WorkspacePath.Replace('\','/').TrimEnd('/'))/"
        if ($content -like "*$needle*") {
            $session.actions.Add([ordered]@{
                id                       = $sessionId
                step                     = '70-git-identity'
                action                   = 'configure_git_identity'
                reversible               = $true
                undone                   = $false
                workspace                = $WorkspacePath
                global_gitconfig_path    = $globalGitconfig
                workspace_gitconfig_path = (Join-Path $WorkspacePath '.gitconfig')
                reconstructed            = $true
                reconstructed_warning    = 'previous_global_email cannot be recovered.'
            })
        }
    }

    # Append to journal.
    $existing = @()
    if ($Script:CABJournalState.sessions) { $existing = @($Script:CABJournalState.sessions) }
    $Script:CABJournalState.sessions = $existing + @($session)
    Save-CABJournal
    return $session
}
