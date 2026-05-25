#requires -Version 7.0
# lib/folder-readmes.ps1 — shared README seeding helper.
#
# Used by step 50 (on folder creation), step 60 (post-clone for
# optional folders that step 60 created as a side-effect), and
# repair --target folder-readmes. Centralizes the template lookup,
# idempotency guard, and journal-entry contract.

function Invoke-CABSeedFolderReadme {
    <#
    .SYNOPSIS
    Copy a template README into a workspace folder, idempotently.

    .DESCRIPTION
    For the given workspace folder, look up the matching template at
    templates/folder-readmes/<folder>/README.md and copy it to
    <workspace>/<folder>/README.md if the workspace target doesn't
    already exist. Emits a yellow warning if the template is missing
    (signal that manifest/folders.yaml has drifted from templates/).
    Journals a 'seed_readme' action on successful copy.

    Returns one of: 'seeded', 'kept', 'no-template', 'failed'.

    .PARAMETER RepoRoot
    Path to the ca-bootstrap repo root (where templates/folder-readmes
    lives).

    .PARAMETER WorkspacePath
    Path to the workspace root.

    .PARAMETER FolderPath
    The folder name (e.g. 'ca-tools') — the relative path under
    WorkspacePath AND the subdirectory under templates/folder-readmes/.

    .PARAMETER StepName
    The step label for journal entries (e.g. '50-folders', '60-repos').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)][string]$StepName
    )

    $template = Join-Path $RepoRoot 'templates/folder-readmes' $FolderPath 'README.md'
    $target = Join-Path $WorkspacePath $FolderPath 'README.md'

    # Template: must be a file. Missing template → manifest/templates drift; warn.
    # Non-file at template path → corrupted templates dir; warn loudly.
    if (-not (Test-Path $template -PathType Leaf)) {
        if (Test-Path $template) {
            Write-CABColor Yellow "    ⚠ Template path exists but is not a file: $template — skipping seed for $FolderPath"
        } else {
            Write-CABColor Yellow "    ⚠ No README template for $FolderPath — skipping seed"
        }
        return 'no-template'
    }

    # Target: if it's already a file, leave it alone (idempotent).
    # If it's a directory, that's a workspace anomaly — warn and skip.
    if (Test-Path $target -PathType Leaf) {
        return 'kept'
    }
    if (Test-Path $target) {
        Write-CABColor Yellow "    ⚠ Target path exists but is not a file: $target — skipping seed for $FolderPath"
        return 'failed'
    }
    try {
        Copy-Item -Path $template -Destination $target -ErrorAction Stop
        Add-CABJournalEntry -Step $StepName -Action 'seed_readme' -Data @{
            path     = $target
            template = $template
        } | Out-Null
        return 'seeded'
    } catch {
        Write-CABColor Yellow "    ⚠ Could not seed README for ${FolderPath}: $($_.Exception.Message)"
        return 'failed'
    }
}
