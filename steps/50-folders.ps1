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
    foreach ($f in $required) {
        $present = Test-Path (Join-Path $Context.WorkspacePath $f.path)
        $marker = if ($present) { '✓' } else { '+' }
        Write-Host ("    {0} {1,-15} {2}" -f $marker, $f.path, $f.description)
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
    foreach ($f in $required) {
        $full = Join-Path $Context.WorkspacePath $f.path
        if (Test-Path $full) {
            $kept++
            continue
        }
        try {
            [void](New-Item -ItemType Directory -Path $full -Force -ErrorAction Stop)
            Add-CABJournalEntry -Step '50-folders' -Action 'create_folder' -Data @{ path = $full } | Out-Null
            $created++
        } catch {
            return @{ status = 'fail'; details = "Failed to create $full : $($_.Exception.Message)" }
        }
    }

    return @{ status = 'ok'; details = "$created created, $kept kept" }
}

function Undo-CABStep50 {
    @{ status = 'noop'; details = 'Reversal handled by undo command (removes empty folders).' }
}
