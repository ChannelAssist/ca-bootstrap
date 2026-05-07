#requires -Version 7.0
# commands/repair.ps1 — fix what doctor found.
#
# Phase 9 implementation. Reuses each step's Invoke function: instead of
# orchestrating the full setup wizard, repair runs only the steps that
# correspond to detected issues.
#
# Targets:
#   --all                       fix every ⚠ and ✗ from doctor
#   --target <tool-id>          install/upgrade a specific tool
#   --target repos              re-clone or fetch missing/broken repos
#   --target repos:<slug>       one specific repo (e.g. repos:cm-shared-libs)
#   --target identity           re-write per-folder git identity
#   --target gh-auth            re-run gh auth login
#   --target folders            recreate any missing top-level folders
#   --target journal            rebuild the journal from on-disk state

function Invoke-CABCommandRepair {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{},
        [switch]$All,
        [string]$Target
    )
    # Repair piggybacks on doctor's check functions.
    . (Join-Path $Context.RepoRoot 'commands/doctor.ps1')

    Write-CABHeader 'ca-bootstrap repair'

    if (-not $All -and -not $Target) {
        Write-CABStatus -Status fail -Message 'You must specify either -All or -Target <id>.'
        Write-Host '    examples:'
        Write-Host '      ca-bootstrap.ps1 repair -All'
        Write-Host '      ca-bootstrap.ps1 repair -Target dotnet-10'
        Write-Host '      ca-bootstrap.ps1 repair -Target repos'
        Write-Host '      ca-bootstrap.ps1 repair -Target repos:cm-shared-libs'
        return 9
    }

    # Always run doctor first so we know what's wrong.
    Write-Host '  Running doctor first...'
    Write-Host ''
    $checks = Invoke-CABDoctorCheck -Context $Context
    $workspace = $Context.WorkspacePath   # populated by Invoke-CABDoctorCheck

    $issues = @($checks | Where-Object { $_.status -in 'warn','fail' })
    if ($issues.Count -eq 0 -and -not $Target) {
        Write-CABStatus -Status ok -Message 'Nothing to repair — all checks ✓.'
        return 0
    }

    # Build target list.
    $targets = if ($All) {
        @($issues.id)
    } else {
        @($Target)
    }

    $applied = 0
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($t in $targets) {
        Write-Host ''
        Write-CABColor White "  → repair $t"
        $result = Invoke-CABRepairTarget -Target $t -Context $Context
        if ($result.ok) {
            Write-CABStatus -Status ok -Message $result.details
            $applied++
        } else {
            Write-CABStatus -Status fail -Message $result.details
            $failed.Add($t)
        }
    }

    Save-CABJournal

    Write-Host ''
    Write-Host "  Re-running doctor to confirm..."
    Write-Host ''
    $afterChecks = Invoke-CABDoctorCheck -Context $Context
    Format-CABDoctorReport -Checks $afterChecks -Summary
    Write-Host ''

    if ($failed.Count -gt 0) {
        Write-CABStatus -Status fail -Message "$($failed.Count) target(s) could not be repaired: $($failed -join ', ')"
        return 9
    }

    # When called with -All, exit non-zero if doctor still reports anything.
    # When called with -Target, only the targeted issue's residual state
    # matters — unrelated warnings stay warnings on the next doctor run.
    $stillBroken = @($afterChecks | Where-Object { $_.status -in 'warn','fail' })
    if ($All -and $stillBroken.Count -gt 0) {
        Write-CABStatus -Status warn -Message "Repair partial — $($stillBroken.Count) issue(s) remain."
        return 9
    }
    Write-CABStatus -Status ok -Message "Repair complete. $applied target(s) fixed."
    return 0
}

# Invoke-CABRepairTarget — dispatch one target string to the corresponding
# step's Invoke function in repair mode.
function Invoke-CABRepairTarget {
    # DoctorChecks was passed to give the dispatcher per-target visibility
    # into the failed checks, but every branch below resolves the work
    # itself by re-invoking the relevant step's Invoke function — none
    # peek at the doctor result. Dropped the parameter; if a future
    # target needs the diagnostics, add it back then.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable]$Context
    )

    # Strip the "tool." prefix doctor uses (so users can type the manifest
    # id directly: --target dotnet-10).
    $bare = $Target -replace '^tool\.', ''

    # Repos sub-target: --target repos:slug
    if ($bare -like 'repos:*') {
        $slug = $bare -replace '^repos:', ''
        return Invoke-CABRepairRepoSlug -Slug $slug -Context $Context
    }

    switch ($bare) {
        'workspace' {
            . (Join-Path $Context.RepoRoot 'steps/40-workspace.ps1')
            $r = Invoke-CABStep40 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'folders' {
            . (Join-Path $Context.RepoRoot 'steps/40-workspace.ps1')
            . (Join-Path $Context.RepoRoot 'steps/50-folders.ps1')
            $r = Invoke-CABStep50 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'gh-auth' {
            . (Join-Path $Context.RepoRoot 'steps/30-gh-auth.ps1')
            $r = Invoke-CABStep30 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'identity' {
            . (Join-Path $Context.RepoRoot 'steps/70-git-identity.ps1')
            $r = Invoke-CABStep70 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'repos' {
            . (Join-Path $Context.RepoRoot 'steps/60-repos.ps1')
            $r = Invoke-CABStep60 -Context $Context
            return @{ ok = ($r.status -in 'ok','skip'); details = $r.details }
        }
        'journal' {
            if (-not $Context.WorkspacePath) {
                return @{ ok = $false; details = 'Workspace path not known; cannot reconstruct journal.' }
            }
            $session = Repair-CABJournal -WorkspacePath $Context.WorkspacePath -Version $Context.Version
            return @{ ok = $true; details = "Reconstructed $(@($session.actions).Count) action(s)" }
        }
        default {
            # Tool ID — install via step 20's machinery.
            $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/tools.yaml')
            $tool = (@($manifest.required) + @($manifest.optional)) | Where-Object { $_.id -eq $bare } | Select-Object -First 1
            if (-not $tool) {
                return @{ ok = $false; details = "Unknown target: $bare" }
            }
            $result = Install-CABTool -Tool $tool -Context $Context
            if ($result.ok) {
                Add-CABJournalEntry -Step '20-prereqs' -Action 'install_tool' -Data @{
                    tool   = $tool.id
                    method = (Get-CABInstallEntry -Tool $tool).type
                } | Out-Null
            }
            return $result
        }
    }
}

function Invoke-CABRepairRepoSlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][hashtable]$Context
    )
    if (-not $Context.WorkspacePath) {
        return @{ ok = $false; details = 'Workspace path not known.' }
    }
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/repos.yaml')
    $allRepos = $manifest.groups | ForEach-Object { $_.repos }
    $repo = $allRepos | Where-Object { $_.repo -ieq $Slug -or $_.repo -ieq "ChannelAssist/$Slug" } | Select-Object -First 1
    if (-not $repo) {
        return @{ ok = $false; details = "Unknown repo: $Slug" }
    }
    $into = Join-Path $Context.WorkspacePath $repo.into
    $state = Test-CABRepoCloned -Path $into -ExpectedRepo $repo.repo
    if ($state -eq 'matches') {
        return @{ ok = $true; details = "Already cloned: $($repo.repo)" }
    }
    $result = Invoke-CABRepoClone -Repo $repo.repo -Into $into -Branch $repo.branch
    if ($result.ok) {
        Add-CABJournalEntry -Step '60-repos' -Action 'clone_repo' -Data @{
            repo = $repo.repo; path = $into; branch = $repo.branch
        } | Out-Null
    }
    return $result
}
