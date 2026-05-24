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
    # -PathType Container ensures Test- mirrors Invoke- semantics: a
    # regular file squatting on a required-folder path counts as
    # missing, not as "present but wrong type". Same discipline on the
    # predecessor walk below — a non-directory predecessor isn't
    # renameable by Invoke-CABStep50 and must not be reported as one.
    $missing  = @($expected | Where-Object { -not (Test-Path (Join-Path $Context.WorkspacePath $_.path) -PathType Container) })
    if ($missing.Count -eq 0) {
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
        # Use -PathType Container everywhere predecessors are classified
        # so the preview matches what Invoke-CABStep50 will actually do
        # — Invoke-CABStep50 only renames directories, so a regular file
        # squatting on the predecessor path must NOT show up as a yellow
        # "↻ rename" in the preview (it would fall through to create).
        $present = Test-Path (Join-Path $Context.WorkspacePath $f.path) -PathType Container
        if ($present) {
            $icon, $color = '✓', 'Green'
            $desc = $f.description
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
