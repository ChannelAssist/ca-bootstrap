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

    Write-CABStep -Number 6 -Total $Context.TotalSteps -Title 'Clone repositories'

    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set — step 40 must run first.' }
    }

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
    if (-not (Test-CABGhAuth)) {
        Write-CABStatus -Status fail -Message 'gh CLI is not authenticated.'
        Write-Host '    Run `gh auth login` and try again. The dedicated auth step lands in phase 5.'
        return @{ status = 'fail'; details = 'gh not authed' }
    }

    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml')

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
    $failedDetails = New-Object System.Collections.Generic.List[string]

    foreach ($g in $manifest.groups) {
        Write-Host ''
        Write-CABColor White "  Group: $($g.name) — $($g.description)"

        $groupChoice = Read-CABChoice -Question "Clone all $($g.repos.Count) repos in this group?" `
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
            continue
        }

        foreach ($repo in $g.repos) {
            $into = Join-Path $Context.WorkspacePath $repo.into
            $state = Test-CABRepoCloned -Path $into -ExpectedRepo $repo.repo
            if ($state -eq 'matches') {
                Write-CABStatus -Status skip -Message "$($repo.repo) already cloned" -Detail $into
                $fetch = Invoke-CABRepoFetch -Path $into
                if ($fetch.ok) { $totalFetched++ }
                continue
            }
            if ($state -eq 'mismatch') {
                Write-CABStatus -Status warn -Message "$($repo.repo) — path exists but is not a matching clone; skipping" -Detail $into
                $totalSkipped++
                continue
            }

            $shouldClone = $true
            if ($groupChoice -ieq 's' -or $repo.opt_in) {
                $promptText = "Clone $($repo.repo)?"
                if ($repo.warn) { Write-CABColor Yellow "    ⓘ $($repo.warn)" }
                $default = -not $repo.opt_in
                $ans = Read-CABConfirm -Question $promptText -Default $default -AnswerKey "repos.repo.$($repo.repo)"
                if ($ans -is [string] -and $ans -eq 'quit') {
                    return @{ status = 'quit'; details = 'User quit during repo cloning.' }
                }
                $shouldClone = ($ans -is [bool] -and $ans)
            }

            if (-not $shouldClone) {
                Write-CABStatus -Status skip -Message "$($repo.repo) skipped"
                $totalSkipped++
                continue
            }

            Write-Host "    cloning $($repo.repo) → $($repo.into)..." -NoNewline
            $result = Invoke-CABRepoClone -Repo $repo.repo -Into $into -Branch $repo.branch
            Write-Host ''
            if ($result.ok) {
                Write-CABStatus -Status ok -Message "$($repo.repo) cloned"
                Add-CABJournalEntry -Step '60-repos' -Action 'clone_repo' -Data @{
                    repo   = $repo.repo
                    path   = $into
                    branch = $repo.branch
                } | Out-Null
                $totalCloned++
            } else {
                Write-CABStatus -Status fail -Message "$($repo.repo) failed" -Detail $result.details
                $failedDetails.Add("$($repo.repo): $($result.details)")
                $totalFailed++
            }
        }
    }

    Write-Host ''
    $summary = "$totalCloned cloned, $totalFetched already-present (fetched), $totalSkipped skipped, $totalFailed failed"
    if ($totalFailed -gt 0) {
        return @{ status = 'fail'; details = "$summary. Errors:`n  $($failedDetails -join "`n  ")" }
    }
    return @{ status = 'ok'; details = $summary }
}

function Undo-CABStep60 {
    @{ status = 'noop'; details = 'Reversal handled by undo command (removes cloned repos with safety checks).' }
}
