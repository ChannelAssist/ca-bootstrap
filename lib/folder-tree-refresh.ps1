#requires -Version 7.0
# lib/folder-tree-refresh.ps1 — regenerate the "## Tree" section of each
# workspace folder's README from the live manifest data.
#
# Used by `repair --target folder-tree-refresh`. The hand-written tree
# blocks in the folder READMEs drift from manifest/repos.yaml whenever
# repos are added/removed/renamed; this target re-syncs them on demand.
#
# Contract:
#   * Only the contents of the first fenced code block under a "## Tree"
#     heading are touched. Prose, other headings, and other code blocks
#     are left intact.
#   * READMEs without a "## Tree" section are skipped with a warning.
#   * Idempotent: a second run reports no-op when nothing changed.
#   * The folder name itself is preserved as the tree root line (so
#     legacy folder names whose README hasn't been renamed still look
#     consistent until the user catches up).

function Get-CABFolderTreeBlock {
    <#
    .SYNOPSIS
    Build the ASCII tree text for one workspace folder, sourced from
    manifest/repos.yaml.

    .DESCRIPTION
    Returns a multi-line string of the form:

        <folder>/
        ├── repo-a/
        ├── repo-b/
        └── repo-c/

    Direct children only (the bootstrap clones one repo per slot, no
    nesting). Entries are sorted case-insensitively by the basename of
    `into`, matching the existing hand-written templates.

    Returns the bare root line ("<folder>/") when the folder has no
    repos in the manifest — this is the correct rendering for empty
    scratch folders like `ca-work-dirs`.

    .PARAMETER FolderPath
    The folder name relative to the workspace root (e.g. 'ca-platform').

    .PARAMETER ReposManifest
    The parsed manifest/repos.yaml object (output of Read-CABManifest).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FolderPath,
        [Parameter(Mandatory)]$ReposManifest
    )

    $prefix = $FolderPath.TrimEnd('/') + '/'
    $children = New-Object System.Collections.Generic.List[string]
    foreach ($group in @($ReposManifest.groups)) {
        foreach ($repo in @($group.repos)) {
            $into = [string]$repo.into
            if (-not $into) { continue }
            # Normalize separators so a Windows-authored manifest still works.
            $into = $into -replace '\\', '/'
            if ($into -like "$prefix*") {
                $rest = $into.Substring($prefix.Length)
                # Only consider direct children (one path segment after the prefix).
                if ($rest -and ($rest -notmatch '/')) {
                    $children.Add($rest)
                }
            }
        }
    }

    # Sort case-insensitively, dedupe (defensive against manifest typos).
    $sorted = @($children | Sort-Object -Unique -Property { $_.ToLowerInvariant() })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("$($FolderPath.TrimEnd('/'))/")
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $isLast = ($i -eq ($sorted.Count - 1))
        $branch = if ($isLast) { '└── ' } else { '├── ' }
        $lines.Add("$branch$($sorted[$i])/")
    }
    return ($lines -join "`n")
}

function Update-CABFolderReadmeTree {
    <#
    .SYNOPSIS
    Replace the contents of the first fenced code block under the
    "## Tree" heading in a README with the supplied tree text.

    .DESCRIPTION
    Returns one of:
      'updated'    — file was rewritten with a new tree
      'kept'       — file already matched the new tree (no-op)
      'no-readme'  — README path doesn't exist
      'no-section' — README has no "## Tree" heading
      'no-fence'   — "## Tree" heading exists but no following fenced code block

    Preserves line endings of the existing file (LF vs CRLF) by reading
    the raw text and rebuilding the content around the matched fence.

    .PARAMETER ReadmePath
    Absolute path to the README to update.

    .PARAMETER Tree
    The replacement tree text (as produced by Get-CABFolderTreeBlock).
    Must not be wrapped in fences itself — only the contents.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReadmePath,
        [Parameter(Mandatory)][string]$Tree
    )

    if (-not (Test-Path $ReadmePath -PathType Leaf)) {
        return 'no-readme'
    }

    $raw = Get-Content -Raw -Path $ReadmePath
    if ($null -eq $raw) { $raw = '' }

    # Locate the "## Tree" heading (must be a heading line — start-of-line,
    # exactly two hashes, then a space, then "Tree", then end-of-line or
    # trailing whitespace). Anything more permissive risks matching prose.
    $headingPattern = '(?m)^##[ \t]+Tree[ \t]*$'
    $headingMatch = [regex]::Match($raw, $headingPattern)
    if (-not $headingMatch.Success) {
        return 'no-section'
    }

    # From the end of the heading line, find the first fenced code block.
    # Block opener: optional leading whitespace + ``` (capture the exact
    # fence so we can reuse it for the rewrite). We don't require a
    # language tag — none of the existing templates use one — but we
    # tolerate it so future templates may add `text` or similar.
    $tail = $raw.Substring($headingMatch.Index + $headingMatch.Length)
    $fencePattern = '(?ms)^[ \t]*(```+)[^\n]*\n(?<body>.*?)(?<=\n)[ \t]*\1[ \t]*$'
    $fenceMatch = [regex]::Match($tail, $fencePattern)
    if (-not $fenceMatch.Success) {
        return 'no-fence'
    }

    $newBody = ($Tree.TrimEnd("`r","`n")) + "`n"
    $existingBody = $fenceMatch.Groups['body'].Value
    if ($existingBody -eq $newBody) {
        return 'kept'
    }

    # Splice: keep everything up to the body capture, swap the body,
    # keep everything after.
    $bodyStartInTail = $fenceMatch.Groups['body'].Index
    $bodyLenInTail   = $fenceMatch.Groups['body'].Length
    $absBodyStart = $headingMatch.Index + $headingMatch.Length + $bodyStartInTail
    $absBodyEnd   = $absBodyStart + $bodyLenInTail
    $rewritten = $raw.Substring(0, $absBodyStart) + $newBody + $raw.Substring($absBodyEnd)

    # Preserve any pre-existing UTF-8 BOM by reading bytes; otherwise
    # write plain UTF-8 (no BOM), matching the rest of the repo.
    Set-Content -Path $ReadmePath -Value $rewritten -Encoding utf8 -NoNewline
    return 'updated'
}

function Invoke-CABFolderTreeRefresh {
    <#
    .SYNOPSIS
    Regenerate the "## Tree" section of every workspace folder README
    from the live manifest.

    .DESCRIPTION
    Walks every folder declared in manifest/folders.yaml. For each
    folder whose README under <workspace>/<folder>/README.md contains a
    "## Tree" section, replaces the fenced tree block with one
    regenerated from manifest/repos.yaml. Idempotent.

    Returns a hashtable @{ status; details; updated; kept; skipped; failed }
    where updated/kept/skipped/failed are arrays of folder paths.

    Status mapping:
      ok    — every readable README either matched or was rewritten
      warn  — at least one README was skipped (missing section/fence)
      fail  — at least one rewrite raised an exception

    .PARAMETER Context
    Standard ca-bootstrap context hashtable. Requires RepoRoot and
    WorkspacePath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    if (-not $Context.RepoRoot) {
        return @{ status = 'fail'; details = 'RepoRoot not set in context.'; updated=@(); kept=@(); skipped=@(); failed=@() }
    }
    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace path not known. Run setup or use --target workspace first.'; updated=@(); kept=@(); skipped=@(); failed=@() }
    }

    $foldersManifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/folders.yaml') -Quiet
    $reposManifest   = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml')   -Quiet

    $updated = New-Object System.Collections.Generic.List[string]
    $kept    = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $failed  = New-Object System.Collections.Generic.List[string]

    foreach ($folder in @($foldersManifest.folders)) {
        $folderPath = [string]$folder.path
        if (-not $folderPath) { continue }
        $readme = Join-Path $Context.WorkspacePath $folderPath 'README.md'

        if (-not (Test-Path $readme -PathType Leaf)) {
            # No README on disk is expected for optional folders that
            # weren't created. Don't escalate — record as skipped so the
            # report stays informative.
            $skipped.Add($folderPath) | Out-Null
            continue
        }

        try {
            $tree = Get-CABFolderTreeBlock -FolderPath $folderPath -ReposManifest $reposManifest
            $result = Update-CABFolderReadmeTree -ReadmePath $readme -Tree $tree
        } catch {
            Write-CABColor Yellow "    ⚠ Could not refresh tree for ${folderPath}: $($_.Exception.Message)"
            $failed.Add($folderPath) | Out-Null
            continue
        }

        switch ($result) {
            'updated' {
                $updated.Add($folderPath) | Out-Null
                try {
                    Add-CABJournalEntry -Step 'repair' -Action 'refresh_folder_tree' -Reversible $false -Data @{
                        folder = $folderPath
                        path   = $readme
                    } | Out-Null
                } catch {
                    # Tests that don't open a session still want the
                    # update to be reported. Journal errors are non-fatal.
                    Write-Verbose "Add-CABJournalEntry skipped: $($_.Exception.Message)"
                }
            }
            'kept'       { $kept.Add($folderPath)       | Out-Null }
            'no-section' {
                Write-CABColor Yellow "    ⚠ $folderPath/README.md has no '## Tree' section — skipped"
                $skipped.Add($folderPath) | Out-Null
            }
            'no-fence'   {
                Write-CABColor Yellow "    ⚠ $folderPath/README.md '## Tree' heading has no fenced code block — skipped"
                $skipped.Add($folderPath) | Out-Null
            }
            default      { $skipped.Add($folderPath) | Out-Null }
        }
    }

    $status = if ($failed.Count -gt 0) { 'fail' }
              elseif ($skipped.Count -gt 0 -and $updated.Count -eq 0 -and $kept.Count -eq 0) { 'warn' }
              else { 'ok' }

    $parts = @()
    if ($updated.Count) { $parts += "$($updated.Count) updated" }
    if ($kept.Count)    { $parts += "$($kept.Count) already in sync" }
    if ($skipped.Count) { $parts += "$($skipped.Count) skipped" }
    if ($failed.Count)  { $parts += "$($failed.Count) failed" }
    if (-not $parts) { $parts = @('no folder READMEs found') }
    $details = $parts -join ', '
    if ($updated.Count -eq 0 -and $failed.Count -eq 0 -and $kept.Count -gt 0) {
        $details = "no-op — $details"
    }

    return @{
        status  = $status
        details = $details
        updated = $updated.ToArray()
        kept    = $kept.ToArray()
        skipped = $skipped.ToArray()
        failed  = $failed.ToArray()
    }
}
