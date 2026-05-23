#requires -Version 7.0
# steps/50-folders.ps1 — create the standard folder skeleton in the workspace.

function Test-CABStep50 {
    [CmdletBinding()]
    param([hashtable]$Context)
    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace path not set. Run setup or use --target workspace first.' }
    }
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml')
    $expected = @($manifest.folders | Where-Object { -not $_.optional })
    $missing  = @($expected | Where-Object { -not (Test-Path (Join-Path $Context.WorkspacePath $_.path)) })
    if ($missing.Count -eq 0) {
        return @{ status = 'ok'; details = "$($expected.Count)/$($expected.Count) folders present" }
    }
    $renamePairs = New-Object System.Collections.Generic.List[string]
    $stillMissing = New-Object System.Collections.Generic.List[string]
    foreach ($f in $missing) {
        $prev = $null
        foreach ($p in @(Get-CABFolderRenamedFrom -Folder $f)) {
            if (Test-Path (Join-Path $Context.WorkspacePath $p)) { $prev = $p; break }
        }
        if ($prev) { $renamePairs.Add("$prev → $($f.path)") }
        else       { $stillMissing.Add([string]$f.path) }
    }
    $parts = @()
    if ($stillMissing.Count -gt 0) { $parts += "$($stillMissing.Count) folder(s) missing: $($stillMissing -join ', ')" }
    if ($renamePairs.Count -gt 0)  { $parts += "$($renamePairs.Count) need rename: $($renamePairs -join ', ')" }
    return @{ status = 'pending'; details = ($parts -join '; ') }
}

function Invoke-CABStep50 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number ($Context.StepOrdinal ?? 5) -Total $Context.TotalSteps -Title 'Folder structure'

    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set — step 40 must run first.' }
    }
    if (-not [System.IO.Path]::IsPathRooted($Context.WorkspacePath)) {
        return @{ status = 'fail'; details = "WorkspacePath '$($Context.WorkspacePath)' is not absolute." }
    }

    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml')
    $required = @($manifest.folders | Where-Object { -not $_.optional })

    Write-Host "  Will ensure these folders under $($Context.WorkspacePath):"
    # Mirror the Format-CABToolReport / Write-CABToolLine pattern so the
    # ✓-row formatting (4 spaces + icon + 2 spaces + 20-wide label +
    # 2 spaces + description) is identical to step 3's tool list.
    # Existing folders → ✓ (Green, no-op needed). Missing with a
    # rename predecessor on disk → ↻ (Yellow, will-rename). Missing
    # outright → + (Cyan, will-create).
    foreach ($f in $required) {
        $present = Test-Path (Join-Path $Context.WorkspacePath $f.path)
        if ($present) {
            $icon, $color = '✓', 'Green'
            $desc = $f.description
        } else {
            $prev = $null
            foreach ($p in @(Get-CABFolderRenamedFrom -Folder $f)) {
                if (Test-Path (Join-Path $Context.WorkspacePath $p)) { $prev = $p; break }
            }
            if ($prev) {
                $icon, $color = '↻', 'Yellow'
                $desc = "rename $prev → $($f.path) ($($f.description))"
            } else {
                $icon, $color = '+', 'Cyan'
                $desc = $f.description
            }
        }
        $label = ([string]$f.path).PadRight(20)
        Write-CABColor ([ConsoleColor]$color) "    $icon  $label  $desc"
    }
    Write-Host ''

    $proceed = Read-CABConfirm -Question 'Continue?' -Default $true -AnswerKey 'folders.continue'
    if (Test-CABQuit $proceed) {
        return @{ status = 'quit'; details = 'User quit at folders step.' }
    }
    if (Test-CABNo $proceed) {
        return @{ status = 'skip'; details = 'User declined to create folders.' }
    }

    $created = 0
    $kept = 0
    $renamed = 0
    foreach ($f in $required) {
        $full = Join-Path $Context.WorkspacePath $f.path
        if (Test-Path $full) {
            $kept++
            continue
        }
        # Walk renamed_from (most-recent → oldest). If a predecessor
        # still exists on disk, rename it into place instead of
        # creating a new empty folder — operators who skipped a
        # previous rename get caught up safely.
        $predecessor = $null
        foreach ($p in @(Get-CABFolderRenamedFrom -Folder $f)) {
            $candidate = Join-Path $Context.WorkspacePath $p
            if (Test-Path $candidate) { $predecessor = $candidate; break }
        }
        if ($predecessor) {
            try {
                Move-Item -LiteralPath $predecessor -Destination $full -ErrorAction Stop
                Add-CABJournalEntry -Step '50-folders' -Action 'rename_folder' -Data @{
                    from = $predecessor
                    to   = $full
                } | Out-Null
                $renamed++
                continue
            } catch {
                return @{ status = 'fail'; details = "Failed to rename $predecessor → $full : $($_.Exception.Message)" }
            }
        }
        try {
            [void](New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop)
            Add-CABJournalEntry -Step '50-folders' -Action 'create_folder' -Data @{ path = $full } | Out-Null
            $created++
        } catch {
            return @{ status = 'fail'; details = "Failed to create $full : $($_.Exception.Message)" }
        }
    }

    $summary = "$created created, $kept kept"
    if ($renamed -gt 0) { $summary += ", $renamed renamed" }
    return @{ status = 'ok'; details = $summary }
}

function Undo-CABStep50 {
    @{ status = 'noop'; details = 'Reversal handled by undo command (removes empty folders).' }
}
