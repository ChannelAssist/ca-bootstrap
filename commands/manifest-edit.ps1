#requires -Version 7.0
# commands/manifest-edit.ps1 — interactive editor that lists every repo
# in the ChannelAssist org against manifest/repos.yaml and lets a
# maintainer add/remove entries without leaving the terminal.
#
# v1 scope (issue #26):
#   * Add missing repos (prompts for group, into-path, branch, opt-in)
#   * Remove existing single-line entries
#   * Multi-line entries (e.g. channel-manager with `large` + `warn`)
#     are listed but rejected with "manual edit needed" — they have
#     too much structure to mutate via surgical text edits, and a
#     full YAML round-trip would mangle the hand-formatted manifest.
#
# Out-of-scope (v1):
#   * Modifying existing entries (group / branch / opt_in changes) —
#     edit the YAML directly for those.

function Invoke-CABCommandManifestEdit {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{},
        [string]$Org = 'ChannelAssist'
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; exit_code = 1; details = 'gh CLI is not installed.' }
    }
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return @{ ok = $false; exit_code = 1; details = 'gh CLI is not authenticated. Run `gh auth login` and try again.' }
    }

    $manifestPath = Join-Path $Context.RepoRoot 'manifest/repos.yaml'
    if (-not (Test-Path $manifestPath)) {
        return @{ ok = $false; exit_code = 1; details = "Manifest not found: $manifestPath" }
    }

    Write-CABHeader 'ca-bootstrap manifest-edit'
    Write-Host "  Org:      $Org"
    Write-Host "  Manifest: $manifestPath"
    Write-Host '  Querying gh for org repos...' -NoNewline

    $rawRepos = & gh repo list $Org --limit 1000 --json nameWithOwner,isArchived,isPrivate,defaultBranchRef 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        return @{ ok = $false; exit_code = 1; details = "gh repo list failed: $($rawRepos -join '; ')" }
    }
    $orgRepos = @($rawRepos | ConvertFrom-Json | Sort-Object nameWithOwner)
    Write-Host " $($orgRepos.Count) found."

    # Read manifest as parsed YAML (for in/out membership checks) and
    # as raw lines (for surgical text edits later).
    $manifest = Read-CABManifest -Path $manifestPath -Quiet
    $manifestRepos = @{}
    foreach ($g in $manifest.groups) {
        foreach ($r in $g.repos) {
            $manifestRepos[[string]$r.repo] = @{
                group   = [string]$g.name
                into    = [string]$r.into
                branch  = [string]$r.branch
                opt_in  = [bool]$r.opt_in
            }
        }
    }
    $groupNames = @($manifest.groups | ForEach-Object { [string]$_.name })
    Write-Host ''

    # Mutation tracker: keep deltas in memory; flush to disk at end on
    # confirmation. This lets the maintainer queue several add/remove
    # actions in a row, then preview the diff before committing.
    $pendingAdds    = New-Object System.Collections.Generic.List[hashtable]
    $pendingRemoves = New-Object System.Collections.Generic.List[string]

    # Auto-queue archived-and-in-manifest entries for removal up front
    # (per maintainer policy: archived repos shouldn't be in the manifest
    # at all). The maintainer can still un-queue them by quitting without
    # saving, but the default action is to clean them up.
    $archivedSlugsInOrg = @{}
    foreach ($r in $orgRepos) {
        if ([bool]$r.isArchived) { $archivedSlugsInOrg[[string]$r.nameWithOwner] = $true }
    }
    foreach ($slug in @($manifestRepos.Keys)) {
        if ($archivedSlugsInOrg.ContainsKey($slug)) {
            [void]$pendingRemoves.Add($slug)
        }
    }
    if ($pendingRemoves.Count -gt 0) {
        Write-CABColor Yellow ("  ⚠ Auto-queued {0} archived-on-GitHub manifest entry(ies) for removal:" -f $pendingRemoves.Count)
        foreach ($slug in $pendingRemoves) {
            Write-CABColor DarkGray "      • $slug (archived; per policy, archived repos don't belong in the manifest)"
        }
        Write-Host ''
    }

    while ($true) {
        Show-CABManifestEditList `
            -OrgRepos $orgRepos `
            -ManifestRepos $manifestRepos `
            -PendingAdds $pendingAdds `
            -PendingRemoves $pendingRemoves

        if ($pendingAdds.Count -gt 0 -or $pendingRemoves.Count -gt 0) {
            Write-Host ''
            Write-CABColor Yellow ("  Pending: +{0} add, -{1} remove" -f $pendingAdds.Count, $pendingRemoves.Count)
        }
        Write-Host ''
        $action = Read-CABChoice -Question 'Action?' `
            -Options @(
                @{ Key = 'a'; Label = 'Add a missing repo' },
                @{ Key = 'r'; Label = 'Remove an existing entry' },
                @{ Key = 's'; Label = 'Save and exit' },
                @{ Key = 'q'; Label = 'Quit without saving' }
            ) `
            -Default 's' `
            -AnswerKey 'manifest-edit.action'

        switch ($action) {
            'a' {
                # Add candidates: in-org, NOT archived (policy: ignore
                # archived), NOT already in manifest, NOT already
                # queued for add this session.
                $missing = @($orgRepos | Where-Object {
                    $slug = [string]$_.nameWithOwner
                    -not [bool]$_.isArchived -and
                    -not $manifestRepos.ContainsKey($slug) -and
                    -not ($pendingAdds | Where-Object { $_.slug -eq $slug })
                })
                if ($missing.Count -eq 0) {
                    Write-CABStatus -Status info -Message 'Nothing missing to add. (Archived repos are excluded by policy — unarchive on GitHub first if you want to bring one in.)'
                    continue
                }
                Add-CABManifestEditEntry -Missing $missing -GroupNames $groupNames -PendingAdds $pendingAdds
            }
            'r' {
                Remove-CABManifestEditEntry `
                    -ManifestRepos $manifestRepos `
                    -PendingRemoves $pendingRemoves
            }
            's' {
                if ($pendingAdds.Count -eq 0 -and $pendingRemoves.Count -eq 0) {
                    Write-CABStatus -Status info -Message 'No changes — exiting.'
                    return @{ ok = $true; exit_code = 0; details = 'no changes' }
                }
                # Apply edits and write back.
                $newContent = Edit-CABManifestText -Path $manifestPath -Adds $pendingAdds -Removes $pendingRemoves
                Write-Host ''
                Write-CABColor White '  Diff preview:'
                Show-CABManifestDiff -OldPath $manifestPath -NewContent $newContent
                Write-Host ''
                $confirm = Read-CABConfirm -Question "Write changes to $manifestPath?" -Default $true -AnswerKey 'manifest-edit.confirm-save'
                if (Test-CABYes $confirm) {
                    Set-Content -Path $manifestPath -Value $newContent -Encoding utf8NoBOM
                    Write-CABStatus -Status ok -Message ("Wrote {0} change(s) to {1}" -f ($pendingAdds.Count + $pendingRemoves.Count), $manifestPath)
                    return @{ ok = $true; exit_code = 0; details = "$($pendingAdds.Count) added, $($pendingRemoves.Count) removed" }
                }
                Write-CABStatus -Status skip -Message 'Changes discarded.'
                return @{ ok = $true; exit_code = 0; details = 'cancelled at write step' }
            }
            'q' {
                if ($pendingAdds.Count -gt 0 -or $pendingRemoves.Count -gt 0) {
                    $reallyQuit = Read-CABConfirm -Question "Discard $($pendingAdds.Count) add + $($pendingRemoves.Count) remove and quit?" -Default $false -AnswerKey 'manifest-edit.confirm-quit'
                    if (-not (Test-CABYes $reallyQuit)) { continue }
                }
                Write-CABStatus -Status info -Message 'Quit without saving.'
                return @{ ok = $true; exit_code = 0; details = 'quit' }
            }
        }
    }
}

function Show-CABManifestEditList {
    [CmdletBinding()]
    param(
        [array]$OrgRepos,
        [hashtable]$ManifestRepos,
        $PendingAdds,
        $PendingRemoves
    )
    Write-Host ''
    Write-CABColor White ("  Repos in {0}-style listing:" -f $OrgRepos.Count)
    foreach ($r in $OrgRepos) {
        $slug = [string]$r.nameWithOwner
        $state = if ($ManifestRepos.ContainsKey($slug)) { 'in' } else { 'out' }
        if ($PendingAdds | Where-Object { $_.slug -eq $slug }) { $state = 'pending-add' }
        if ($PendingRemoves -contains $slug)                   { $state = 'pending-remove' }

        $mark, $color = switch ($state) {
            'in'             { '[x]', 'White' }
            'out'            { '[ ]', 'DarkGray' }
            'pending-add'    { '[+]', 'Cyan' }
            'pending-remove' { '[-]', 'Yellow' }
        }

        $extras = @()
        if ($r.isPrivate)  { $extras += 'private' }
        if ($r.isArchived) { $extras += 'archived' }
        $extraText = if ($extras.Count -gt 0) { " ($($extras -join ', '))" } else { '' }

        $pathInfo = if ($state -eq 'in') {
            $m = $ManifestRepos[$slug]
            $optInTag = if ($m.opt_in) { ', opt-in' } else { '' }
            "  $($m.into) ($($m.branch)$optInTag)"
        } else {
            "  → suggested group: $(Get-CABSuggestedGroup -Slug $slug)"
        }

        Write-CABColor ([ConsoleColor]$color) ("    {0,-3}  {1,-50}{2}{3}" -f $mark, $slug, $extraText, $pathInfo)
    }
}

function Add-CABManifestEditEntry {
    [CmdletBinding()]
    param(
        [array]$Missing,
        [array]$GroupNames,
        $PendingAdds
    )
    Write-Host ''
    Write-CABColor White '  Missing repos:'
    for ($i = 0; $i -lt $Missing.Count; $i++) {
        $r = $Missing[$i]
        $extras = @()
        if ($r.isPrivate)  { $extras += 'private' }
        if ($r.isArchived) { $extras += 'archived' }
        $extraText = if ($extras.Count -gt 0) { " ($($extras -join ', '))" } else { '' }
        Write-Host ("    {0,3}) {1}{2}" -f ($i + 1), $r.nameWithOwner, $extraText)
    }
    Write-Host ''
    Write-Host -NoNewline '  Pick number to add (or "b" to go back): '
    $pick = Read-Host
    if ($pick -ieq 'b' -or [string]::IsNullOrWhiteSpace($pick)) { return }
    if (-not ($pick -match '^\d+$')) { Write-CABStatus -Status warn -Message 'Not a number.'; return }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $Missing.Count) { Write-CABStatus -Status warn -Message 'Out of range.'; return }
    $repo = $Missing[$idx]
    $slug = [string]$repo.nameWithOwner
    $name = ($slug -split '/')[-1]
    $defaultGroup  = Get-CABSuggestedGroup -Slug $slug
    $defaultBranch = if ($repo.defaultBranchRef.name) { [string]$repo.defaultBranchRef.name } else { 'main' }

    Write-Host -NoNewline "  Group [$defaultGroup] (one of: $($GroupNames -join ', ')): "
    $group = Read-Host
    if ([string]::IsNullOrWhiteSpace($group)) { $group = $defaultGroup }
    if ($group -notin $GroupNames -and $group -ne 'unsorted') {
        Write-CABColor Yellow "    ⚠ '$group' isn't an existing group. Will be added under that name; you may need to also create it in manifest/folders.yaml."
    }

    Write-Host -NoNewline "  Path under workspace [$group/$name]: "
    $into = Read-Host
    if ([string]::IsNullOrWhiteSpace($into)) { $into = "$group/$name" }

    Write-Host -NoNewline "  Branch [$defaultBranch]: "
    $branch = Read-Host
    if ([string]::IsNullOrWhiteSpace($branch)) { $branch = $defaultBranch }

    $optIn = Read-CABConfirm -Question 'Mark as opt-in (only clone when explicitly chosen)?' -Default $false -AnswerKey "manifest-edit.optin.$slug"

    $entry = @{
        slug   = $slug
        group  = $group
        into   = $into
        branch = $branch
        opt_in = (Test-CABYes $optIn)
    }
    $PendingAdds.Add($entry)
    Write-CABStatus -Status ok -Message "Queued add: $slug → $group/$name ($branch)$(if ($entry.opt_in) { ' [opt-in]' })"
}

function Remove-CABManifestEditEntry {
    [CmdletBinding()]
    param(
        [hashtable]$ManifestRepos,
        $PendingRemoves
    )
    $candidates = @($ManifestRepos.Keys | Sort-Object | Where-Object { $PendingRemoves -notcontains $_ })
    if ($candidates.Count -eq 0) {
        Write-CABStatus -Status info -Message 'Nothing left to remove.'
        return
    }
    Write-Host ''
    Write-CABColor White '  Manifest entries:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $slug = $candidates[$i]
        $m = $ManifestRepos[$slug]
        Write-Host ("    {0,3}) {1,-50} {2} ({3})" -f ($i + 1), $slug, $m.into, $m.branch)
    }
    Write-Host ''
    Write-Host -NoNewline '  Pick number to remove (or "b" to go back): '
    $pick = Read-Host
    if ($pick -ieq 'b' -or [string]::IsNullOrWhiteSpace($pick)) { return }
    if (-not ($pick -match '^\d+$')) { Write-CABStatus -Status warn -Message 'Not a number.'; return }
    $idx = [int]$pick - 1
    if ($idx -lt 0 -or $idx -ge $candidates.Count) { Write-CABStatus -Status warn -Message 'Out of range.'; return }
    $slug = $candidates[$idx]
    $confirm = Read-CABConfirm -Question "Queue removal of $slug?" -Default $false -AnswerKey "manifest-edit.confirm-remove.$slug"
    if (-not (Test-CABYes $confirm)) { return }
    $PendingRemoves.Add($slug) | Out-Null
    Write-CABStatus -Status ok -Message "Queued remove: $slug"
}

# Edit-CABManifestText — apply queued add/remove ops to manifest/repos.yaml
# via line-level surgery. Preserves existing formatting (compact-flow
# `- { repo: ..., into: ..., branch: ... }` style); refuses to touch
# multi-line entries (which are rare and hand-tuned).
function Edit-CABManifestText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        $Adds,
        $Removes
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    Get-Content -Path $Path | ForEach-Object { $lines.Add($_) }

    # ---- Removes (drop matching single-line repo entries) ----
    foreach ($slug in $Removes) {
        $idx = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            # Match: `      - { repo: ChannelAssist/foo, ...`
            if ($line -match "^\s*-\s*\{\s*repo:\s*$([regex]::Escape($slug))\b") {
                $idx = $i
                break
            }
        }
        if ($null -eq $idx) {
            # Multi-line entry or unhandled shape — skip with a warning.
            Write-CABStatus -Status warn -Message "$slug is multi-line or non-standard in the manifest; remove it manually."
            continue
        }
        $lines.RemoveAt($idx)
    }

    # ---- Adds (append to chosen group's repos: block) ----
    # For each add, find the group's `- name: <group>` then walk forward
    # until we hit the next `  - name: ` (next group) or end of file,
    # then insert before that boundary.
    foreach ($entry in $Adds) {
        $newLine = ConvertTo-CABManifestRepoLine -Entry $entry
        $insertIdx = Find-CABGroupInsertIndex -Lines $lines -GroupName $entry.group
        if ($null -eq $insertIdx) {
            # Group doesn't exist yet — append a new group block at end
            # of the `groups:` list. Conservative: warn and skip; v2
            # could prompt to create the group.
            Write-CABStatus -Status warn -Message "Group '$($entry.group)' does not exist in the manifest. Add it manually under 'groups:' and re-run, or pick an existing group."
            continue
        }
        $lines.Insert($insertIdx, $newLine)
    }

    return ($lines -join "`n") + "`n"
}

# Find-CABGroupInsertIndex — return the line index where a new repo
# entry should be inserted within the named group. The right spot is
# just before the blank line that terminates the group's repos: block,
# or at end-of-file if it's the last group.
function Find-CABGroupInsertIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Lines,
        [Parameter(Mandatory)][string]$GroupName
    )
    # Locate the group header.
    $groupStart = $null
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*-\s*name:\s*$([regex]::Escape($GroupName))\s*$") {
            $groupStart = $i
            break
        }
    }
    if ($null -eq $groupStart) { return $null }

    # Walk forward until we hit either (a) the next group header
    # (`  - name: `) or (b) end of file. The insert position is the
    # line BEFORE that boundary, skipping any trailing blank lines so
    # the new entry stays inside the group's repos: block.
    $endIdx = $Lines.Count
    for ($j = $groupStart + 1; $j -lt $Lines.Count; $j++) {
        if ($Lines[$j] -match '^\s*-\s*name:\s') {
            $endIdx = $j
            break
        }
    }
    # Walk back from endIdx through trailing blank lines.
    $insertIdx = $endIdx
    while ($insertIdx -gt $groupStart -and [string]::IsNullOrWhiteSpace($Lines[$insertIdx - 1])) {
        $insertIdx--
    }
    return $insertIdx
}

function ConvertTo-CABManifestRepoLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Entry)
    $optInPart = if ($Entry.opt_in) { ', opt_in: true' } else { '' }
    return "      - {{ repo: {0}, into: {1}, branch: {2}{3} }}" -f `
        $Entry.slug, $Entry.into, $Entry.branch, $optInPart
}

function Show-CABManifestDiff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewContent
    )
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tmp -Value $NewContent -Encoding utf8NoBOM -NoNewline
        $diff = & diff -u $OldPath $tmp 2>&1
        if (-not $diff) {
            Write-CABColor DarkGray '    (no changes)'
            return
        }
        foreach ($line in $diff) {
            $color = switch -Regex ($line) {
                '^\+\+\+|^---|^@@' { 'Cyan' }
                '^\+'              { 'Green' }
                '^-'               { 'Red' }
                default            { 'DarkGray' }
            }
            Write-CABColor ([ConsoleColor]$color) "    $line"
        }
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}
