#requires -Version 7.0
# steps/60-repos.ps1 — clone repos group by group.

function Test-CABStep60 {
    [CmdletBinding()]
    param([hashtable]$Context)
    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set.' }
    }
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml')
    $allRepos = $manifest.groups | ForEach-Object { $_.repos }
    $expected = @($allRepos | Where-Object { -not $_.opt_in })
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($r in $expected) {
        $full = Join-Path $Context.WorkspacePath $r.into
        $state = Test-CABRepoCloned -Path $full -ExpectedRepo $r.repo
        if ($state -ne 'matches') { $missing.Add("$($r.repo) ($state)") }
    }
    if ($missing.Count -eq 0) {
        return @{ status = 'ok'; details = "$($expected.Count)/$($expected.Count) repos present" }
    }
    return @{ status = 'pending'; details = "$($missing.Count)/$($expected.Count) repo(s) need cloning" }
}

function Invoke-CABStep60 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number ($Context.StepOrdinal ?? 6) -Total $Context.TotalSteps -Title 'Clone repositories'

    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set — step 40 must run first.' }
    }

    # Defensive: refuse to clone into a relative path. A relative WorkspacePath
    # would land every clone inside the user's current directory, which has
    # been a real failure mode (see TEST_PLAN.md §3.1).
    if (-not [System.IO.Path]::IsPathRooted($Context.WorkspacePath)) {
        return @{ status = 'fail'; details = "WorkspacePath '$($Context.WorkspacePath)' is not absolute. Refusing to clone (would write to your current directory)." }
    }
    Write-CABColor DarkGray "    Cloning into: $($Context.WorkspacePath)"

    # Phase 2 prereq check: git + gh + gh auth.
    if (-not (Test-CABCommandAvailable 'git')) {
        Write-CABStatus -Status fail -Message 'git is not installed.'
        Write-Host '    Phase 2 expects git already installed; tool install lands in phase 3-4.'
        Write-Host '    Install git, then re-run setup.'
        return @{ status = 'fail'; details = 'git missing' }
    }
    if (-not (Test-CABCommandAvailable 'gh')) {
        Write-CABStatus -Status fail -Message 'gh CLI is not installed.'
        Write-Host '    Phase 2 expects gh already installed; tool install lands in phase 3-4.'
        Write-Host '    Install gh, then re-run setup.'
        return @{ status = 'fail'; details = 'gh missing' }
    }
    # Test-mode seam: skip gh auth check; use a fixture manifest that points
    # at file:// repos clonable without auth (see TEST_PLAN.md §8.1).
    if (-not ($Context.TestMode -and $Context.TestGhUser)) {
        if (-not (Test-CABGhAuth)) {
            Write-CABStatus -Status fail -Message 'gh CLI is not authenticated.'
            Write-Host '    Run `gh auth login` and try again. The dedicated auth step lands in phase 5.'
            return @{ status = 'fail'; details = 'gh not authed' }
        }
    }

    $reposPath = if ($Context.TestMode -and $Context.TestReposFile) { $Context.TestReposFile } else { Join-Path $Context.RepoRoot 'manifest/repos.yaml' }
    $manifest = Read-CABManifest -Path $reposPath

    Write-Host '  Repository groups:'
    foreach ($g in $manifest.groups) {
        $count = $g.repos.Count
        $optIn = ($g.repos | Where-Object { $_.opt_in } | Measure-Object).Count
        $note = if ($optIn -gt 0) { " ($optIn opt-in)" } else { '' }
        Write-Host ("    {0,-14} {1,2} repos$note  — {2}" -f $g.name, $count, $g.description)
    }
    Write-Host ''

    $totalCloned = 0
    $totalSkipped = 0
    $totalFetched = 0
    $totalFailed = 0
    # Mismatch is its own bucket — distinct from "user said no" or
    # "group skipped". A mismatch means a path exists with a wrong/
    # broken clone (often a partially-cloned .git missing HEAD/config),
    # which the user has to clean up manually before re-running.
    $totalMismatch = 0
    $mismatchPaths = New-Object System.Collections.Generic.List[string]
    $failedDetails = New-Object System.Collections.Generic.List[string]

    # Per-repo [N/total] counter so a long clone batch surfaces "where
    # are we in the queue" without the user having to count rows. Total
    # is across all groups so the numerator is monotonic — group skips
    # advance the counter by the group's repo count.
    $progressIndex = 0
    $progressTotal = ($manifest.groups | ForEach-Object { $_.repos.Count } | Measure-Object -Sum).Sum

    # Group-level counter on the loud header line so position info is
    # visible even on whole-group skips (the per-repo counter only
    # surfaces inside a group the user accepted).
    $groupIndex = 0
    $groupTotal = $manifest.groups.Count

    foreach ($g in $manifest.groups) {
        $groupIndex++
        Write-Host ''
        Write-CABColor White "  Group $groupIndex/${groupTotal}: $($g.name) — $($g.description)"
        # List the repos so the user can see exactly what they'll be
        # confirming. Without this, "Clone all 5 repos in ca-platform?"
        # is opaque — the user has no way to know what's about to land
        # on disk without flipping to manifest/repos.yaml.
        foreach ($repo in $g.repos) {
            $hint = if ($repo.opt_in) { ' (opt-in)' } else { '' }
            Write-CABColor DarkGray "      • $($repo.repo)$hint"
        }
        Write-Host ''

        $groupChoice = Read-CABChoice -Question "Clone all $($g.repos.Count) repos in $($g.name)?" `
            -Options @(
                @{ Key = 'Y'; Label = 'Yes' },
                @{ Key = 'n'; Label = 'No (skip group)' },
                @{ Key = 's'; Label = 'Select' }
            ) `
            -Default 'Y' `
            -AnswerKey "repos.group.$($g.name)"

        if ($groupChoice -eq 'quit') {
            return @{ status = 'quit'; details = 'User quit during repo cloning.' }
        }
        if ($groupChoice -ieq 'n') {
            Write-CABStatus -Status skip -Message "Group $($g.name) skipped."
            # Account for the whole group's worth of repos so the
            # end-of-step summary reflects what actually happened.
            # Without this, a "no" on every group would still print
            # "0 skipped" — caught by Copilot review on PR #17 after
            # the per-repo $progressCurrent accumulator was removed
            # alongside the TUI progress bar.
            $totalSkipped += $g.repos.Count
            $progressIndex += $g.repos.Count
            continue
        }

        foreach ($repo in $g.repos) {
            $progressIndex++
            $progressPrefix = "[$progressIndex/$progressTotal]"
            $into = Join-Path $Context.WorkspacePath $repo.into
            # Final paranoia check before any disk mutation.
            if (-not [System.IO.Path]::IsPathRooted($into)) {
                return @{ status = 'fail'; details = "Computed clone path '$into' is not absolute (workspace='$($Context.WorkspacePath)', into='$($repo.into)')." }
            }
            $state = Test-CABRepoCloned -Path $into -ExpectedRepo $repo.repo
            if ($state -eq 'matches') {
                Write-CABStatus -Status skip -Prefix $progressPrefix -Message "$($repo.repo) already cloned" -Detail $into
                $fetch = Invoke-CABRepoFetch -Path $into
                if ($fetch.ok) { $totalFetched++ }
                continue
            }
            if ($state -eq 'mismatch') {
                Write-CABStatus -Status warn -Prefix $progressPrefix -Message "$($repo.repo) — path exists but is not a valid clone of this repo; skipping" -Detail $into
                $totalMismatch++
                $mismatchPaths.Add($into)
                continue
            }

            $shouldClone = $true
            if ($groupChoice -ieq 's' -or $repo.opt_in) {
                $promptText = "$progressPrefix Clone $($repo.repo)?"
                if ($repo.warn) { Write-CABColor Yellow "    ⓘ $($repo.warn)" }
                $default = -not $repo.opt_in
                $ans = Read-CABConfirm -Question $promptText -Default $default -AnswerKey "repos.repo.$($repo.repo)"
                if (Test-CABQuit $ans) {
                    return @{ status = 'quit'; details = 'User quit during repo cloning.' }
                }
                $shouldClone = (Test-CABYes $ans)
            }

            if (-not $shouldClone) {
                Write-CABStatus -Status skip -Prefix $progressPrefix -Message "$($repo.repo) skipped"
                $totalSkipped++
                continue
            }

            # Bright prefix so the [N/total] pops visually against the
            # surrounding plain text — without a colored icon (no ✓/↷)
            # the in-progress line was reading dim and the marker was
            # easy to miss. Route through Write-CABColor so NO_COLOR /
            # CA_BOOTSTRAP_NO_COLOR are honored consistently with the
            # rest of the wizard (Copilot review, PR #17).
            Write-Host '    ' -NoNewline
            Write-CABColor Cyan $progressPrefix -NoNewLine
            Write-Host " cloning $($repo.repo) → $into..." -NoNewline
            $result = Invoke-CABRepoClone -Repo $repo.repo -Into $into -Branch $repo.branch
            Write-Host ''
            if ($result.ok) {
                Write-CABStatus -Status ok -Prefix $progressPrefix -Message "$($repo.repo) cloned"
                Add-CABJournalEntry -Step '60-repos' -Action 'clone_repo' -Data @{
                    repo   = $repo.repo
                    path   = $into
                    branch = $repo.branch
                } | Out-Null
                $totalCloned++
            } else {
                Write-CABStatus -Status fail -Prefix $progressPrefix -Message "$($repo.repo) failed" -Detail $result.details
                $failedDetails.Add("$($repo.repo): $($result.details)")
                $totalFailed++
            }
        }
    }

    Write-Host ''
    if ($totalMismatch -gt 0) {
        # Surface a single recovery hint at the end — repeating it on
        # every mismatch line would just be noise. The paths are listed
        # above (each with its own ⚠ row); this tells the user how to
        # unstick them. We don't try to auto-fix because the path could
        # contain uncommitted user work; manual confirmation is right.
        Write-CABColor Yellow "  ⓘ $totalMismatch path(s) exist but aren't valid clones. Inspect each path,"
        Write-CABColor Yellow "    then either delete it manually or run 'ca-bootstrap.ps1 undo' to remove"
        Write-CABColor Yellow "    everything this session tracked. Re-run setup to re-clone."
        Write-Host ''
    }
    $summary = "$totalCloned cloned, $totalFetched already-present (fetched), $totalSkipped skipped, $totalMismatch mismatched, $totalFailed failed"
    if ($totalFailed -gt 0) {
        return @{ status = 'fail'; details = "$summary. Errors:`n  $($failedDetails -join "`n  ")" }
    }
    return @{ status = 'ok'; details = $summary }
}

function Undo-CABStep60 {
    @{ status = 'noop'; details = 'Reversal handled by undo command (removes cloned repos with safety checks).' }
}
