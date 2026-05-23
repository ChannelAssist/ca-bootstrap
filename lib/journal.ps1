#requires -Version 7.0
# lib/journal.ps1 — action journal: read, write, append, query, recover.
#
# Phase 7 implementation. The journal is the source of truth for what
# ca-bootstrap has done on this machine. doctor (phase 8), repair (phase 9),
# and undo (phase 10) all consume it via Get-CABJournalEntry and update
# it via Set-CABEntryUndone.
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
# Monotonic per-process counter that disambiguates entry ids when two
# Add-CABJournalEntry / Repair-CABJournal calls land in the same wall-
# clock instant. Set-CABEntryUndone matches by id string, so two entries
# sharing an id would be marked undone together — see the format
# documented on New-CABEntryId below.
$Script:CABEntryIdSequence     = 0

# ---------------------------------------------------------------------------
# Path accessors
# ---------------------------------------------------------------------------

function Get-CABTranscriptPath { $Script:CABootstrapTranscript }
function Get-CABJournalPath    { $Script:CABootstrapJournalPath }
function Get-CABSessionId      { $Script:CABootstrapSessionId }
function Get-CABStateDir       { $Script:CABootstrapStateDir }

# Test-CABContainsSensitive — returns $true if the input string contains a
# pattern that looks like a credential. Used by the journal/transcript
# layers to refuse to record secrets even if a step accidentally tries to.
$Script:CABSensitivePatterns = @(
    '\bgh[pousr]_[A-Za-z0-9_]{30,}'                      # gh CLI token prefixes
    '\bgithub_pat_[A-Za-z0-9_]{20,}'                     # newer fine-grained PAT
    '\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}'        # JWT (3-segment, dot-separated)
    '\bAKIA[0-9A-Z]{16}\b'                               # AWS access key id
    '\bxox[abprs]-[A-Za-z0-9-]{10,}'                     # Slack tokens
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'                 # PEM private key
)
function Test-CABContainsSensitive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    foreach ($p in $Script:CABSensitivePatterns) {
        if ($Text -match $p) { return $true }
    }
    return $false
}

# Hide-CABSensitive — replace each known-token pattern with <redacted:type>.
function Hide-CABSensitive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $out = $Text
    foreach ($p in $Script:CABSensitivePatterns) {
        $out = [regex]::Replace($out, $p, '<redacted>')
    }
    return $out
}

# Reset-CABJournalState — re-read CA_BOOTSTRAP_STATE and reset in-memory
# state. Useful for tests that mutate the env var between cases (their
# `$Script:` assignments don't reach this lib's scope).
function Reset-CABJournalState {
    $Script:CABootstrapStateDir    = if ($env:CA_BOOTSTRAP_STATE) { $env:CA_BOOTSTRAP_STATE } else { Join-Path $HOME '.ca-bootstrap' }
    $Script:CABootstrapJournalPath = Join-Path $Script:CABootstrapStateDir 'journal.yaml'
    $Script:CABootstrapTranscript  = Join-Path $Script:CABootstrapStateDir 'last-run.log'
    $Script:CABootstrapSessionId   = $null
    $Script:CABJournalState        = $null
    $Script:CABEntryIdSequence     = 0
}

# New-CABEntryId — produce a journal entry id that is guaranteed unique
# within a process. Format: `yyyy-MM-ddTHH:mm:ss.fffZ-N` where N is a
# monotonically incrementing per-process counter (reset by
# Reset-CABJournalState). Sub-second precision keeps human ordering
# meaningful; the counter guarantees correctness even when the OS clock
# has coarse resolution (legacy Windows DateTime can land on the same
# tick for back-to-back calls). Set-CABEntryUndone is a string-equality
# match, so backward compatibility is preserved — old whole-second ids
# in existing journals continue to undo correctly.
function New-CABEntryId {
    $Script:CABEntryIdSequence++
    $now = (Get-Date -AsUTC).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    return "$now-$Script:CABEntryIdSequence"
}

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

# ---------------------------------------------------------------------------
# Lockfile (single-writer guarantee)
# ---------------------------------------------------------------------------
#
# Two parallel `setup` invocations would race on the journal and the
# transcript. The lockfile is a tiny advisory mutex: each command grabs it
# at session start, holds the open handle for the duration of the run,
# and releases it at session end (or on process exit, since the OS will
# clean up the handle).

$Script:CABLockDirAcquired = $null

function Lock-CABSession {
    [CmdletBinding()]
    param([int]$TimeoutMs = 0)
    Initialize-CABJournal
    # Use a *directory* as the mutex. mkdir is atomic across every OS
    # (POSIX + NTFS) — succeeds for exactly one caller; subsequent calls
    # fail until the dir is removed. .NET's File.Open + FileShare is
    # advisory on Unix and doesn't actually enforce single-writer.
    $lockDir = Join-Path $Script:CABootstrapStateDir 'session.lock.d'
    $deadline = [Environment]::TickCount + $TimeoutMs
    while ($true) {
        try {
            [void][System.IO.Directory]::CreateDirectory($Script:CABootstrapStateDir)
            # CreateDirectory is non-atomic (succeeds even if dir exists),
            # so we use the .NET DirectoryInfo.Create path with a guard.
            if (Test-Path $lockDir) {
                throw [System.IO.IOException]::new("Lock directory exists: $lockDir")
            }
            $di = New-Object System.IO.DirectoryInfo $lockDir
            $di.Create()
            $Script:CABLockDirAcquired = $lockDir
            # Stamp PID so other processes can identify the holder.
            $holderFile = Join-Path $lockDir 'holder'
            "pid=$PID started=$(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH:mm:ssZ')" | Set-Content -Path $holderFile -Encoding utf8NoBOM
            return $true
        } catch [System.IO.IOException] {
            # Stale-lock check: holder process gone → reclaim.
            if (Test-CABStaleLock -Path (Join-Path $lockDir 'holder')) {
                Remove-Item -Path $lockDir -Recurse -Force -ErrorAction SilentlyContinue
                continue
            }
            if ([Environment]::TickCount -ge $deadline) {
                throw [CABSessionLockedException]::new($lockDir, (Get-CABLockHolder (Join-Path $lockDir 'holder')))
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Get-CABLockHolder {
    param([string]$Path)
    try {
        $content = (Get-Content $Path -Raw -ErrorAction SilentlyContinue)
        if (-not $content) { return $null }
        $h = @{}
        foreach ($pair in ($content.Trim() -split '\s+')) {
            if ($pair -match '^([^=]+)=(.+)$') { $h[$Matches[1]] = $Matches[2] }
        }
        return $h
    } catch { return $null }
}

function Test-CABStaleLock {
    param([string]$Path)
    $holder = Get-CABLockHolder $Path
    if (-not $holder -or -not $holder.pid) { return $true }   # malformed / empty → stale
    try {
        $proc = Get-Process -Id ([int]$holder.pid) -ErrorAction Stop
        # Process exists with that PID. Treat as live regardless of name,
        # because (a) cross-platform process naming varies (pwsh-preview,
        # pwsh-7, etc.) and (b) a recycled PID is rare enough that an
        # explicit -ForceUnlock is the right escape hatch.
        return ($null -eq $proc)
    } catch {
        return $true   # Get-Process couldn't find a process with that PID → stale
    }
}

# Custom exception so the orchestrator can catch it and emit a friendly
# message instead of a stack trace.
class CABSessionLockedException : System.Exception {
    [string]$LockPath
    [hashtable]$Holder
    CABSessionLockedException([string]$path, [hashtable]$holder) : base("ca-bootstrap session lock held") {
        $this.LockPath = $path
        $this.Holder = $holder
    }
}

function Unlock-CABSession {
    if ($Script:CABLockDirAcquired) {
        Remove-Item -Path $Script:CABLockDirAcquired -Recurse -Force -ErrorAction SilentlyContinue
        $Script:CABLockDirAcquired = $null
    }
}

# Get-CABCurrentSessionAction — return only this run's journal entries,
# in reverse chronological order. Used by Invoke-CABQuitWithRollbackOffer
# to roll back what the user just did, without touching prior sessions.
function Get-CABCurrentSessionAction {
    $session = Get-CABCurrentSession
    if (-not $session) { return ,@() }
    # Materialize the list before filtering so PowerShell's pipeline
    # doesn't expand a List<hashtable> into something with the wrong
    # .Count semantics. Without the comma-prefix-and-array-cast dance
    # below, .Count occasionally reports the underlying capacity rather
    # than the number of items.
    $actionsArr = [hashtable[]](@($session.actions))
    $open = @($actionsArr | Where-Object { -not $_.undone })
    $sorted = @($open | Sort-Object -Property id -Descending)
    return ,$sorted
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
        [Parameter(Mandatory)] [ValidateSet('setup','doctor','repair','undo','manifest-drift','manifest-edit')] [string]$Command,
        [Parameter(Mandatory)] [string]$Version,
        [string]$WorkspacePath,
        [int]$LockTimeoutMs = 0
    )
    # Refuse to run if another session is in progress. doctor is read-only
    # so we let it through without a lock.
    if ($Command -ne 'doctor') {
        Lock-CABSession -TimeoutMs $LockTimeoutMs
    }
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
    try { Stop-Transcript | Out-Null } catch { Write-Verbose "No active transcript to stop." }
    Unlock-CABSession
}

# Get-CABCurrentSession — returns a reference to the current session
# hashtable so steps can mutate its `actions` list directly.
#
# "Current" means the session Start-CABSession created in THIS process
# run, identified by $Script:CABootstrapSessionId. Returning `sessions[-1]`
# unconditionally would mis-classify the last prior session loaded from
# disk as active — in production where the journal already has dozens of
# prior sessions, Add-CABJournalEntry would then silently append to the
# previous session instead of throwing "No active session". The PR #80
# review caught this regression; the seeded-prior-session test below
# pins it.
function Get-CABCurrentSession {
    if (-not $Script:CABootstrapSessionId) { return $null }
    if (-not $Script:CABJournalState -or -not $Script:CABJournalState.sessions) { return $null }
    $sessions = @($Script:CABJournalState.sessions)
    if ($sessions.Count -eq 0) { return $null }
    # Match by id rather than position so the lookup is robust to any
    # future rearrangement of $Script:CABJournalState.sessions.
    $match = $sessions | Where-Object { $_.id -eq $Script:CABootstrapSessionId } | Select-Object -First 1
    if ($match) { return $match }
    return $null
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
    # No session active = bug, not a test convenience. A silent $null
    # return creates invisible audit-trail gaps in production: the
    # action looks like it journaled, the caller assumes success, but
    # the audit record never materializes. Tests must opt in to a
    # session via Start-CABSession (or seed one through Repair-).
    # PR #80 + the journal-session-required.tests.ps1 suite pin this.
    if (-not $session) { throw 'No active session — call Start-CABSession first.' }

    $entry = [ordered]@{
        id         = New-CABEntryId
        step       = $Step
        action     = $Action
        reversible = $Reversible
        undone     = $false
    }
    foreach ($k in $Data.Keys) {
        $v = $Data[$k]
        # Best-effort: refuse to journal a string that looks like a credential.
        # The action types we expose don't carry secrets; this is a guard
        # against future bugs and contributors who might accidentally pass
        # a token through Data.
        if ($v -is [string] -and (Test-CABContainsSensitive $v)) {
            $entry[$k] = Hide-CABSensitive $v
        } else {
            $entry[$k] = $v
        }
    }

    # Convert .actions to a List if powershell-yaml gave us an array.
    if ($session.actions -isnot [System.Collections.Generic.List[hashtable]]) {
        $tmp = New-Object System.Collections.Generic.List[hashtable]
        foreach ($a in @($session.actions)) { $tmp.Add($a) }
        $session.actions = $tmp
    }
    $session.actions.Add($entry)
    return $entry
}

# Get-CABJournalEntry — query across all sessions in the loaded journal.
#   -Action <name>     filter by action type (e.g. 'clone_repo')
#   -Step <id>         filter by step id (e.g. '60-repos')
#   -OnlyOpen          return entries where undone == false (default)
#   -IncludeUndone     also include entries marked undone
#   -SessionCommand    filter by the session.command that produced the entry
function Get-CABJournalEntry {
    # -OnlyOpen used to be the inverse of -IncludeUndone but was never
    # wired in (the body always uses IncludeUndone). Removed to drop
    # the dead switch — callers that filter for "open" entries already
    # rely on the default behavior (undone entries excluded unless
    # IncludeUndone is passed).
    [CmdletBinding()]
    param(
        [string]$Action,
        [string]$Step,
        [string]$SessionCommand,
        [switch]$IncludeUndone
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

# Set-CABEntryUndone — set undone = true on the original entry, identified
# by its `id` field (timestamps are unique within the journal).
function Set-CABEntryUndone {
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

    # Workspace folder. Emit both create_folder (so undo can mkdir-undo
    # if the user later asks with --include-folders) and select_workspace
    # (so the new doctor read order finds the reconstructed workspace
    # without falling back to the legacy filter). Two entries, two
    # different jobs — see steps/40-workspace.ps1 for the same split on
    # live runs.
    if (Test-Path $WorkspacePath) {
        $session.actions.Add([ordered]@{
            id                = New-CABEntryId
            step              = '40-workspace'
            action            = 'create_folder'
            reversible        = $true
            undone            = $false
            path              = $WorkspacePath
            is_workspace_root = $true
            reconstructed     = $true
        })
        $session.actions.Add([ordered]@{
            id                = New-CABEntryId
            step              = '40-workspace'
            action            = 'select_workspace'
            reversible        = $false
            undone            = $false
            path              = $WorkspacePath
            is_workspace_root = $true
            created           = $false
            reconstructed     = $true
        })
    }

    # Sub-folders.
    foreach ($sub in 'docs','ca-platform','cm-product','ado-legacy') {
        $full = Join-Path $WorkspacePath $sub
        if (Test-Path $full) {
            $session.actions.Add([ordered]@{
                id            = New-CABEntryId
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
                    id            = New-CABEntryId
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
                id                       = New-CABEntryId
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
