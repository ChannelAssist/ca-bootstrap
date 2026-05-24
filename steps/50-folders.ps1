#requires -Version 7.0
# steps/50-folders.ps1 — create the standard folder skeleton in the workspace.

# Source the README-seed helper (used here + in step 60 + in repair).
if (-not (Get-Command 'Invoke-CABSeedFolderReadme' -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '../lib/folder-readmes.ps1')
}

function Test-CABStep50 {
    [CmdletBinding()]
    param([hashtable]$Context)
    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace path not set. Run setup or use --target workspace first.' }
    }
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml')
    $expected = @($manifest.folders | Where-Object { -not $_.optional })

    # Classify each required folder into one of three buckets, mirroring
    # Invoke-CABStep50's execution branches exactly. Without distinguishing
    # collisions (path exists as non-directory) from genuinely missing
    # folders, a collision would be reported as "missing" + "renameable"
    # in the diagnostic — but Invoke-CABStep50 would actually fail with
    # "exists but is not a directory" before the rename could fire.
    $collisions   = New-Object System.Collections.Generic.List[string]
    $missing      = New-Object System.Collections.Generic.List[hashtable]
    $presentCount = 0
    foreach ($f in $expected) {
        $target = Join-Path $Context.WorkspacePath $f.path
        if (Test-Path $target -PathType Container) {
            $presentCount++
        } elseif (Test-Path $target) {
            $collisions.Add([string]$f.path) | Out-Null
        } else {
            $missing.Add($f) | Out-Null
        }
    }

    if ($collisions.Count -eq 0 -and $missing.Count -eq 0) {
        return @{ status = 'ok'; details = "$($expected.Count)/$($expected.Count) folders present" }
    }

    $renamePairs = New-Object System.Collections.Generic.List[string]
    $stillMissing = New-Object System.Collections.Generic.List[string]
    foreach ($f in $missing) {
        $prev = $null
        foreach ($p in @(Get-CABFolderRenamedFrom -Folder $f)) {
            if (Test-Path (Join-Path $Context.WorkspacePath $p) -PathType Container) { $prev = $p; break }
        }
        if ($prev) { $renamePairs.Add("$prev → $($f.path)") }
        else       { $stillMissing.Add([string]$f.path) }
    }

    $parts = @()
    if ($collisions.Count -gt 0)   { $parts += "$($collisions.Count) collision(s) (exists but not a directory): $($collisions -join ', ')" }
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
        # Preview ordering must match Invoke-CABStep50's execution
        # branches exactly. The three categories in priority order:
        #   1. ✓ Present (path exists as directory) — no-op.
        #   2. ✗ Collision (path exists but is NOT a directory) —
        #      Invoke-CABStep50 will fail with "exists but is not a
        #      directory". Must not be rendered as "↻ rename" even if
        #      a predecessor directory is sitting on disk; the rename
        #      branch would fail before it ever fires.
        #   3. Missing entirely — predecessor walk decides between
        #      "↻ rename" and "+ create".
        $target = Join-Path $Context.WorkspacePath $f.path
        $targetIsDir  = Test-Path $target -PathType Container
        $targetExists = Test-Path $target
        if ($targetIsDir) {
            $icon, $color = '✓', 'Green'
            $desc = $f.description
        } elseif ($targetExists) {
            # Non-directory squatter at the required path. Render as
            # a red collision so the operator knows the run will fail
            # at this step and they need to resolve manually.
            $icon, $color = '✗', 'Red'
            $desc = "path exists but is not a directory ($($f.description))"
        } else {
            $prev = $null
            foreach ($p in @(Get-CABFolderRenamedFrom -Folder $f)) {
                if (Test-Path (Join-Path $Context.WorkspacePath $p) -PathType Container) { $prev = $p; break }
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
    $seededReadmes = 0
    foreach ($f in $required) {
        $full = Join-Path $Context.WorkspacePath $f.path
        if (Test-Path $full -PathType Container) {
            $kept++
        } elseif (Test-Path $full) {
            # Path exists but isn't a directory — fail clearly rather than silently
            # mis-categorising or trying to seed a README under a non-directory.
            return @{ status = 'fail'; details = "Path '$full' exists but is not a directory; resolve manually." }
        } else {
            # Folder is missing. Walk renamed_from (most-recent → oldest)
            # first so an operator who skipped a previous rename gets
            # caught up safely — moving the predecessor into place
            # preserves any user data inside. Fall back to fresh create
            # only when no predecessor exists on disk.
            $predecessor = $null
            foreach ($p in @(Get-CABFolderRenamedFrom -Folder $f)) {
                $candidate = Join-Path $Context.WorkspacePath $p
                if (Test-Path $candidate -PathType Container) { $predecessor = $candidate; break }
            }
            if ($predecessor) {
                try {
                    Move-Item -LiteralPath $predecessor -Destination $full -ErrorAction Stop
                    Add-CABJournalEntry -Step '50-folders' -Action 'rename_folder' -Data @{
                        from = $predecessor
                        to   = $full
                    } | Out-Null
                    $renamed++
                } catch {
                    return @{ status = 'fail'; details = "Failed to rename $predecessor → $full : $($_.Exception.Message)" }
                }
            } else {
                try {
                    [void](New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop)
                    Add-CABJournalEntry -Step '50-folders' -Action 'create_folder' -Data @{ path = $full } | Out-Null
                    $created++
                } catch {
                    return @{ status = 'fail'; details = "Failed to create $full : $($_.Exception.Message)" }
                }
            }
        }

        # README seeding: idempotent, never overwrites a user-edited README.
        # Missing template → warn (signals the manifest is out of sync with templates/).
        # Copy failure → warn and continue (non-fatal). Runs for kept,
        # created, AND renamed folders so the seed catches operators
        # who landed here through any path.
        if (Test-Path $full -PathType Container) {
            $result = Invoke-CABSeedFolderReadme `
                -RepoRoot $Context.RepoRoot `
                -WorkspacePath $Context.WorkspacePath `
                -FolderPath $f.path `
                -StepName '50-folders'
            if ($result -eq 'seeded') { $seededReadmes++ }
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
        if (-not (Test-Path $full -PathType Container)) {
            if (Test-Path $full) {
                Write-CABColor Yellow "    ⚠ Optional folder path '$full' exists but is not a directory — skipping README seed"
            }
            continue
        }
        $result = Invoke-CABSeedFolderReadme `
            -RepoRoot $Context.RepoRoot `
            -WorkspacePath $Context.WorkspacePath `
            -FolderPath $f.path `
            -StepName '50-folders'
        if ($result -eq 'seeded') { $seededReadmes++ }
    }

    $summary = "$created created, $kept kept"
    if ($renamed -gt 0) { $summary += ", $renamed renamed" }
    $summary += ", $seededReadmes README(s) seeded"
    return @{ status = 'ok'; details = $summary }
}

function Undo-CABStep50 {
    @{ status = 'noop'; details = 'Reversal handled by undo command (removes empty folders).' }
}
