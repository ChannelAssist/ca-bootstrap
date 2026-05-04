#requires -Version 7.0
# commands/undo.ps1 — reverse changes recorded in the action journal.
#
# Phase 10 implementation. Walks the journal in reverse and dispatches
# each entry to a per-action reverser. Strong safety rules:
#   - Refuse to delete a directory with uncommitted git changes (without --force)
#   - Refuse to delete a directory with files unknown to the journal (without --force)
#   - Tool installs are NOT reversed unless --include-tools (per-tool confirm)
#   - WSL is never auto-reversed (prints manual instructions)
#
# After reversal each entry is marked undone in the journal; the journal
# is preserved (not deleted) so the operation is auditable.

function Invoke-CABCommandUndo {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{},
        [string]$Target,
        [switch]$IncludeTools,
        [switch]$IncludeFolders,
        [switch]$Force
    )
    Write-CABHeader 'ca-bootstrap undo'

    Read-CABJournal | Out-Null
    $entries = @(Get-CABJournalEntries -IncludeUndone:$false)
    if ($entries.Count -eq 0) {
        Write-CABStatus -Status info -Message 'No reversible actions recorded in the journal.'
        return 0
    }

    # Filter by target if provided.
    if ($Target) {
        $entries = @(Filter-CABUndoEntries -Entries $entries -Target $Target)
        if ($entries.Count -eq 0) {
            Write-CABStatus -Status info -Message "No reversible actions match target '$Target'."
            return 0
        }
    }

    # Categorize so the user can decide group-by-group.
    $byCategory = Group-CABUndoEntries -Entries $entries -IncludeTools:$IncludeTools

    Write-Host ''
    Write-Host '  Reversible actions found:'
    foreach ($cat in $byCategory.Keys) {
        $items = @($byCategory[$cat])
        Write-Host "    [$cat] $($items.Count) action(s)"
    }
    Write-Host ''

    if (-not $Context.Force -and -not $Force -and -not $Target) {
        $proceed = Read-CABConfirm -Question 'Proceed with reversal (each destructive action will be re-confirmed)?' -Default $false -AnswerKey 'undo.proceed'
        if ($proceed -is [string] -and $proceed -eq 'quit') { return 1 }
        if ($proceed -is [bool] -and -not $proceed) {
            Write-CABStatus -Status info -Message 'No changes made.'
            return 0
        }
    }

    $undone = 0
    $skipped = 0
    $failed = New-Object System.Collections.ArrayList

    # Walk entries in REVERSE chronological order (LIFO).
    $sortedEntries = $entries | Sort-Object -Property id -Descending

    foreach ($entry in $sortedEntries) {
        $result = Invoke-CABUndoEntry -Entry $entry -IncludeTools:$IncludeTools -IncludeFolders:$IncludeFolders -Force:$Force -Context $Context
        switch ($result.status) {
            'ok'      { $undone++ ; Mark-CABEntryUndone -EntryId $entry.id | Out-Null }
            'skip'    { $skipped++ }
            'noop'    { $skipped++ ; Mark-CABEntryUndone -EntryId $entry.id | Out-Null }
            'refused' { $skipped++ }
            'fail'    { [void]$failed.Add("$($entry.action): $($result.details)") }
        }
    }

    Save-CABJournal

    # Snapshot the journal post-undo for audit.
    $snapshot = "$(Get-CABJournalPath).undone-$(Get-Date -AsUTC -Format 'yyyy-MM-ddTHH-mm-ssZ')"
    Copy-Item -Path (Get-CABJournalPath) -Destination $snapshot -Force -ErrorAction SilentlyContinue

    Write-Host ''
    if ($failed.Count -gt 0) {
        Write-CABStatus -Status fail -Message "$undone reversed, $skipped skipped, $($failed.Count) failed"
        foreach ($f in $failed) { Write-Host "    • $f" }
        Write-Host "    Journal snapshot: $snapshot"
        return 7
    }
    Write-CABStatus -Status ok -Message "$undone reversed, $skipped skipped"
    Write-Host "    Journal snapshot: $snapshot"
    return 0
}

# ---------------------------------------------------------------------------
# Filter / group helpers
# ---------------------------------------------------------------------------

function Filter-CABUndoEntries {
    param([array]$Entries, [string]$Target)
    $bare = $Target -replace '^tool\.', ''
    if ($bare -like 'repos:*') {
        $slug = $bare -replace '^repos:', ''
        return $Entries | Where-Object { $_.action -eq 'clone_repo' -and ($_.repo -ieq $slug -or $_.repo -ieq "ChannelAssist/$slug") }
    }
    switch ($bare) {
        'identity'  { return $Entries | Where-Object { $_.action -eq 'configure_git_identity' } }
        'repos'     { return $Entries | Where-Object { $_.action -eq 'clone_repo' } }
        'workspace' { return $Entries | Where-Object { $_.is_workspace_root } }
        'folders'   { return $Entries | Where-Object { $_.action -eq 'create_folder' -and -not $_.is_workspace_root } }
        'gh-auth'   { return $Entries | Where-Object { $_.action -eq 'gh_auth_login' } }
        default     { return $Entries | Where-Object { $_.tool -eq $bare -or $_.action -eq "install_$bare" } }
    }
}

function Group-CABUndoEntries {
    param([array]$Entries, [switch]$IncludeTools)
    $byCategory = [ordered]@{}
    $byCategory['identity']     = @($Entries | Where-Object { $_.action -eq 'configure_git_identity' })
    $byCategory['workspace']    = @($Entries | Where-Object { $_.action -eq 'create_workspace_file' })
    $byCategory['plugin']       = @($Entries | Where-Object { $_.action -eq 'install_ca_claude_plugin' })
    $byCategory['repos']        = @($Entries | Where-Object { $_.action -eq 'clone_repo' })
    $byCategory['folders']      = @($Entries | Where-Object { $_.action -eq 'create_folder' })
    $byCategory['gh-auth']      = @($Entries | Where-Object { $_.action -eq 'gh_auth_login' })
    if ($IncludeTools) {
        $byCategory['tools'] = @($Entries | Where-Object { $_.action -eq 'install_tool' })
    }
    # Drop empty categories
    $filtered = [ordered]@{}
    foreach ($k in $byCategory.Keys) { if ($byCategory[$k].Count -gt 0) { $filtered[$k] = $byCategory[$k] } }
    return $filtered
}

# ---------------------------------------------------------------------------
# Per-action reversers
# ---------------------------------------------------------------------------

function Invoke-CABUndoEntry {
    param([hashtable]$Entry, [switch]$IncludeTools, [switch]$IncludeFolders, [switch]$Force, [hashtable]$Context)

    Write-Host ''
    Write-Host "  → undo $($Entry.action) [$($Entry.id)]"

    switch ($Entry.action) {
        'configure_git_identity' { return Invoke-CABUndoIdentity -Entry $Entry -Force:$Force }
        'clone_repo'             { return Invoke-CABUndoCloneRepo -Entry $Entry -Force:$Force }
        'create_folder'          { return Invoke-CABUndoCreateFolder -Entry $Entry -IncludeFolders:$IncludeFolders -Force:$Force }
        'create_workspace_file'  { return Invoke-CABUndoWorkspaceFile -Entry $Entry }
        'install_ca_claude_plugin' { return Invoke-CABUndoPluginLink -Entry $Entry }
        'gh_auth_login'          { return Invoke-CABUndoGhAuth -Entry $Entry }
        'install_tool'           { return Invoke-CABUndoToolInstall -Entry $Entry -IncludeTools:$IncludeTools -Context $Context }
        'install_wsl'            {
            Write-CABStatus -Status info -Message 'WSL install is not auto-reversed. To remove manually: `wsl --unregister Ubuntu-22.04`'
            return @{ status = 'noop'; details = 'WSL reversal must be manual' }
        }
        default {
            return @{ status = 'noop'; details = "Unknown action type: $($Entry.action)" }
        }
    }
}

function Invoke-CABUndoIdentity {
    param([hashtable]$Entry, [switch]$Force)
    $globalPath = [string]$Entry.global_gitconfig_path
    $wsPath     = [string]$Entry.workspace_gitconfig_path
    $workspace  = [string]$Entry.workspace

    if (-not (Test-Path $globalPath)) {
        return @{ status = 'noop'; details = 'Global .gitconfig already absent.' }
    }

    $content = Get-Content -Raw $globalPath
    $pattern = "gitdir:$($workspace.Replace('\','/').TrimEnd('/'))/"

    # Remove the [includeIf "gitdir:..."] block AND the path = ... line below it
    # AND the preceding comment we add.
    $lines = $content -split "`n"
    $out = New-Object System.Collections.ArrayList
    $skip = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($skip -gt 0) { $skip-- ; continue }
        if ($line -match '^\s*# Added by ca-bootstrap' -and ($i + 1) -lt $lines.Count -and $lines[$i+1] -like "*$pattern*") {
            $skip = 2  # this comment + the [includeIf ...] line + the path = line
            continue
        }
        if ($line -like "*$pattern*") {
            $skip = 1  # the [includeIf ...] line + the path = line
            continue
        }
        [void]$out.Add($line)
    }
    Set-Content -Path $globalPath -Value (($out -join "`n").TrimEnd() + "`n") -NoNewline:$false

    if (Test-Path $wsPath) {
        Remove-Item -Path $wsPath -Force
    }
    return @{ status = 'ok'; details = "Removed includeIf and workspace .gitconfig" }
}

function Invoke-CABUndoCloneRepo {
    param([hashtable]$Entry, [switch]$Force)
    $path = [string]$Entry.path
    if (-not (Test-Path $path)) {
        return @{ status = 'noop'; details = "$path already absent" }
    }
    if (-not $Force) {
        # Safety: refuse if uncommitted changes.
        $dirty = & git -C $path status --porcelain 2>$null
        if ($dirty) {
            Write-CABStatus -Status warn -Message "$($Entry.repo) has uncommitted changes — skipping (use -Force to override)"
            return @{ status = 'refused'; details = 'uncommitted changes' }
        }
        # Safety: refuse if HEAD is ahead of origin (unpushed work).
        $unpushed = & git -C $path log '@{u}..HEAD' --oneline 2>$null
        if ($unpushed) {
            Write-CABStatus -Status warn -Message "$($Entry.repo) has unpushed commits — skipping (use -Force to override)"
            return @{ status = 'refused'; details = 'unpushed commits' }
        }
    }
    Remove-Item -Path $path -Recurse -Force
    return @{ status = 'ok'; details = "Removed $path" }
}

function Invoke-CABUndoCreateFolder {
    param([hashtable]$Entry, [switch]$IncludeFolders, [switch]$Force)
    $path = [string]$Entry.path
    if (-not (Test-Path $path)) {
        return @{ status = 'noop'; details = "$path already absent" }
    }
    # Don't remove top-level workspace unless explicitly requested.
    if ($Entry.is_workspace_root -and -not $IncludeFolders) {
        Write-CABStatus -Status info -Message "Keeping workspace root $path (use -IncludeFolders to remove)"
        return @{ status = 'skip'; details = 'workspace root preserved' }
    }
    # Only remove if empty (no surprise deletions).
    $children = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue
    if ($children -and $children.Count -gt 0 -and -not $Force) {
        Write-CABStatus -Status warn -Message "$path is not empty — skipping (use -Force to override)"
        return @{ status = 'refused'; details = 'directory not empty' }
    }
    Remove-Item -Path $path -Recurse -Force
    return @{ status = 'ok'; details = "Removed $path" }
}

function Invoke-CABUndoWorkspaceFile {
    param([hashtable]$Entry)
    $path = [string]$Entry.path
    if (-not (Test-Path $path)) { return @{ status = 'noop'; details = 'already absent' } }
    Remove-Item -Path $path -Force
    return @{ status = 'ok'; details = "Removed $path" }
}

function Invoke-CABUndoPluginLink {
    param([hashtable]$Entry)
    $linkPath = [string]$Entry.link_path
    if (-not (Test-Path $linkPath)) { return @{ status = 'noop'; details = 'link already absent' } }
    Remove-Item -Path $linkPath -Force
    return @{ status = 'ok'; details = "Removed $linkPath" }
}

function Invoke-CABUndoGhAuth {
    param([hashtable]$Entry)
    & gh auth logout --hostname github.com 2>$null
    if ($LASTEXITCODE -ne 0) {
        return @{ status = 'noop'; details = 'gh logout already done or unavailable' }
    }
    return @{ status = 'ok'; details = 'Logged out of gh' }
}

function Invoke-CABUndoToolInstall {
    param([hashtable]$Entry, [switch]$IncludeTools, [hashtable]$Context)
    if (-not $IncludeTools) {
        Write-CABStatus -Status skip -Message "Tool $($Entry.tool) install kept (pass -IncludeTools to uninstall)"
        return @{ status = 'skip'; details = 'tool reversal opt-in only' }
    }
    $confirm = Read-CABConfirm -Question "Uninstall $($Entry.tool)? Other projects may depend on it." -Default $false
    if ($confirm -is [string] -and $confirm -eq 'quit') { return @{ status = 'skip'; details = 'user quit' } }
    if ($confirm -is [bool] -and -not $confirm) { return @{ status = 'skip'; details = 'user declined' } }

    $method = [string]$Entry.method
    switch ($method) {
        'winget' { & winget uninstall --silent $Entry.tool | Out-Host }
        'brew'   { & brew uninstall $Entry.tool | Out-Host }
        'apt'    { & sudo apt-get remove -y $Entry.tool | Out-Host }
        'dnf'    { & sudo dnf remove -y $Entry.tool | Out-Host }
        'snap'   { & sudo snap remove $Entry.tool | Out-Host }
        'npm'    { & npm uninstall -g $Entry.tool | Out-Host }
        default  {
            Write-CABStatus -Status info -Message "Cannot auto-uninstall via $method — please remove $($Entry.tool) manually"
            return @{ status = 'noop'; details = "manual removal needed for $method" }
        }
    }
    if ($LASTEXITCODE -ne 0) {
        return @{ status = 'fail'; details = "$method uninstall exited $LASTEXITCODE" }
    }
    return @{ status = 'ok'; details = "Uninstalled $($Entry.tool) via $method" }
}
