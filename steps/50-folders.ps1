#requires -Version 7.0
# steps/50-folders.ps1 — create the standard folder skeleton in the workspace.

function Test-CABStep50 {
    [CmdletBinding()]
    param([hashtable]$Context)
    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace path not set. Run setup or use --target workspace first.' }
    }
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml')
    $expected = @($manifest.folders | Where-Object { -not $_.optional } | ForEach-Object { $_.path })
    $missing  = $expected | Where-Object { -not (Test-Path (Join-Path $Context.WorkspacePath $_)) }
    if ($missing.Count -eq 0) {
        return @{ status = 'ok'; details = "$($expected.Count)/$($expected.Count) folders present" }
    }
    return @{ status = 'pending'; details = "$($missing.Count) folder(s) missing: $($missing -join ', ')" }
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
    # Existing folders → ✓ (Green, no-op needed). Missing → + (Cyan,
    # will-create).
    foreach ($f in $required) {
        $present = Test-Path (Join-Path $Context.WorkspacePath $f.path)
        $icon, $color = if ($present) { '✓', 'Green' } else { '+', 'Cyan' }
        $label = ([string]$f.path).PadRight(20)
        Write-CABColor ([ConsoleColor]$color) "    $icon  $label  $($f.description)"
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
    $seededReadmes = 0
    foreach ($f in $required) {
        $full = Join-Path $Context.WorkspacePath $f.path
        if (Test-Path $full) {
            $kept++
        } else {
            try {
                [void](New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop)
                Add-CABJournalEntry -Step '50-folders' -Action 'create_folder' -Data @{ path = $full } | Out-Null
                $created++
            } catch {
                return @{ status = 'fail'; details = "Failed to create $full : $($_.Exception.Message)" }
            }
        }

        # README seeding: idempotent, never overwrites a user-edited README.
        # Missing template → warn (signals the manifest is out of sync with templates/).
        # Copy failure → warn and continue (non-fatal).
        $template = Join-Path $Context.RepoRoot 'templates/folder-readmes' $f.path 'README.md'
        $target   = Join-Path $full 'README.md'
        if (-not (Test-Path $template)) {
            Write-CABColor Yellow "    ⚠ No README template for $($f.path) — skipping seed"
        } elseif (-not (Test-Path $target)) {
            try {
                Copy-Item -Path $template -Destination $target -ErrorAction Stop
                Add-CABJournalEntry -Step '50-folders' -Action 'seed_readme' -Data @{
                    path     = $target
                    template = $template
                } | Out-Null
                $seededReadmes++
            } catch {
                Write-CABColor Yellow "    ⚠ Could not seed README for $($f.path): $($_.Exception.Message)"
            }
        }
    }

    # Seed READMEs for OPTIONAL folders that exist on disk. Optional folders
    # are not created by this step (they're created later by step 60 when their
    # repo group is cloned, or manually by the user). We only seed when the
    # folder already exists — never create folders here that the user didn't
    # ask for. Required folders were handled by the loop above.
    $optional = @($manifest.folders | Where-Object { $_.optional })
    foreach ($f in $optional) {
        $full = Join-Path $Context.WorkspacePath $f.path
        if (-not (Test-Path $full -PathType Container)) { continue }
        $template = Join-Path $Context.RepoRoot 'templates/folder-readmes' $f.path 'README.md'
        $target   = Join-Path $full 'README.md'
        if (-not (Test-Path $template)) {
            Write-CABColor Yellow "    ⚠ No README template for $($f.path) — skipping seed"
            continue
        }
        if (Test-Path $target) { continue }
        try {
            Copy-Item -Path $template -Destination $target -ErrorAction Stop
            Add-CABJournalEntry -Step '50-folders' -Action 'seed_readme' -Data @{
                path     = $target
                template = $template
            } | Out-Null
            $seededReadmes++
        } catch {
            Write-CABColor Yellow "    ⚠ Could not seed README for $($f.path): $($_.Exception.Message)"
        }
    }

    return @{ status = 'ok'; details = "$created created, $kept kept, $seededReadmes README(s) seeded" }
}

function Undo-CABStep50 {
    @{ status = 'noop'; details = 'Reversal handled by undo command (removes empty folders).' }
}
