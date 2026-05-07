#requires -Version 7.0
# commands/manifest-drift.ps1 — surface drift between manifest/repos.yaml
# and the actual ChannelAssist GitHub org. Opt-in maintenance command;
# not part of the user-facing setup/doctor/repair/undo flow.
#
# Output kinds:
#   • "on GitHub but not in manifest" — new repos created in the org
#   • "in manifest but not on GitHub" — deleted/renamed/archived repos
#   • "in manifest AND on GitHub but archived" — soft-removable
#
# The command does NOT mutate the manifest. It produces a PR-ready
# YAML snippet (commented out; the maintainer reviews + pastes into
# the manifest with the right group assignment).

function Invoke-CABCommandManifestDrift {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{},
        [string]$Org = 'ChannelAssist',
        # When set, emit only the JSON drift report (no human formatting).
        # Useful for CI / pre-commit hooks that want to assert "no drift".
        [switch]$Json
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; details = 'gh CLI is not installed.' }
    }
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return @{ ok = $false; details = 'gh CLI is not authenticated. Run `gh auth login` and try again.' }
    }

    $manifestPath = Join-Path $Context.RepoRoot 'manifest/repos.yaml'
    if (-not (Test-Path $manifestPath)) {
        return @{ ok = $false; details = "Manifest not found: $manifestPath" }
    }
    $manifest = Read-CABManifest -Path $manifestPath

    # Map of slug → @{ repo; group; archived (filled later) } from manifest.
    $manifestRepos = @{}
    foreach ($g in $manifest.groups) {
        foreach ($r in $g.repos) {
            $manifestRepos[[string]$r.repo] = @{
                slug      = [string]$r.repo
                group     = $g.name
                into      = [string]$r.into
                branch    = [string]$r.branch
                opt_in    = [bool]$r.opt_in
            }
        }
    }

    if (-not $Json) {
        Write-CABHeader 'ca-bootstrap manifest-drift'
        Write-Host "  Org: $Org"
        Write-Host "  Manifest: $manifestPath"
        Write-Host "  Querying gh for org repos..." -NoNewline
    }
    # `gh repo list` paginates; --limit 1000 is the safe upper bound.
    # We capture isArchived too so archived repos can be flagged in the
    # report (they're still "on GitHub" but probably shouldn't be in
    # the bootstrap manifest).
    $rawRepos = & gh repo list $Org --limit 1000 --json nameWithOwner,isArchived,isPrivate,defaultBranchRef 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $Json) { Write-Host '' }
        return @{ ok = $false; details = "gh repo list failed: $($rawRepos -join '; ')" }
    }
    $orgRepos = $rawRepos | ConvertFrom-Json
    if (-not $Json) {
        Write-Host " $($orgRepos.Count) found."
        Write-Host ''
    }

    $orgSlugs = @{}
    foreach ($r in $orgRepos) {
        $orgSlugs[[string]$r.nameWithOwner] = $r
    }

    $missing  = New-Object System.Collections.Generic.List[hashtable]   # in org, not in manifest
    $stale    = New-Object System.Collections.Generic.List[hashtable]   # in manifest, not in org
    $archived = New-Object System.Collections.Generic.List[hashtable]   # in both, but archived on GitHub

    foreach ($slug in $orgSlugs.Keys) {
        if (-not $manifestRepos.ContainsKey($slug)) {
            $missing.Add(@{
                slug    = $slug
                private = [bool]$orgSlugs[$slug].isPrivate
                default = [string]$orgSlugs[$slug].defaultBranchRef.name
                # Suggest a group based on naming convention. Maintainer
                # can override; this is just a starting hint.
                suggested_group = (Get-CABSuggestedGroup -Slug $slug)
            })
        } elseif ($orgSlugs[$slug].isArchived) {
            $archived.Add(@{
                slug  = $slug
                group = $manifestRepos[$slug].group
            })
        }
    }
    foreach ($slug in $manifestRepos.Keys) {
        if (-not $orgSlugs.ContainsKey($slug)) {
            $stale.Add(@{
                slug  = $slug
                group = $manifestRepos[$slug].group
                into  = $manifestRepos[$slug].into
            })
        }
    }

    if ($Json) {
        $report = [ordered]@{
            org             = $Org
            org_repo_count  = $orgRepos.Count
            manifest_count  = $manifestRepos.Count
            missing         = @($missing)
            stale           = @($stale)
            archived        = @($archived)
            drift_total     = $missing.Count + $stale.Count + $archived.Count
        }
        # Bypass PowerShell's pipeline so the orchestrator's `$r = Invoke...`
        # capture doesn't swallow the JSON payload alongside the
        # status-hashtable return value. [Console]::WriteLine writes
        # straight to stdout.
        [Console]::WriteLine(($report | ConvertTo-Json -Depth 6))
        return @{ ok = ($report.drift_total -eq 0); details = "Drift JSON emitted ($($report.drift_total) item(s))." }
    }

    # Human-readable report.
    Write-CABColor White "  Manifest: $($manifestRepos.Count) repos across $($manifest.groups.Count) groups"
    Write-CABColor White "  Org:      $($orgRepos.Count) repos"
    Write-Host ''

    if ($missing.Count -eq 0 -and $stale.Count -eq 0 -and $archived.Count -eq 0) {
        Write-CABStatus -Status ok -Message 'No drift — manifest is in sync with the org.'
        return @{ ok = $true; details = 'in sync' }
    }

    if ($missing.Count -gt 0) {
        Write-CABColor Yellow "  ⚠ $($missing.Count) repo(s) on GitHub but NOT in the manifest:"
        Write-Host ''
        foreach ($g in ($missing | Group-Object suggested_group)) {
            Write-CABColor White "    Suggested group: $($g.Name)"
            foreach ($m in $g.Group) {
                $tag = if ($m.private) { ' (private)' } else { '' }
                Write-Host "      • $($m.slug)$tag — default branch: $($m.default)"
            }
            Write-Host ''
            # PR-ready YAML snippet
            Write-CABColor DarkGray "    Paste under group `"$($g.Name)`" in manifest/repos.yaml:"
            foreach ($m in $g.Group) {
                $name  = ($m.slug -split '/')[-1]
                $into  = "$($g.Name)/$name"
                $brnch = if ($m.default) { $m.default } else { 'main' }
                Write-CABColor Cyan ("      - {{ repo: {0}, into: {1}, branch: {2} }}" -f $m.slug, $into, $brnch)
            }
            Write-Host ''
        }
    }

    if ($stale.Count -gt 0) {
        Write-CABColor Yellow "  ⚠ $($stale.Count) repo(s) in the manifest but NOT on GitHub (deleted/renamed/private):"
        Write-Host ''
        foreach ($s in $stale) {
            Write-Host "    • $($s.slug) (group: $($s.group), into: $($s.into))"
        }
        Write-CABColor DarkGray "    Remove these entries from manifest/repos.yaml."
        Write-Host ''
    }

    if ($archived.Count -gt 0) {
        Write-CABColor Yellow "  ⚠ $($archived.Count) repo(s) archived on GitHub (still in manifest):"
        Write-Host ''
        foreach ($a in $archived) {
            Write-Host "    • $($a.slug) (group: $($a.group))"
        }
        Write-CABColor DarkGray "    Archived repos clone read-only; consider removing from the manifest."
        Write-Host ''
    }

    $total = $missing.Count + $stale.Count + $archived.Count
    return @{ ok = $false; details = "$total drift item(s) — see report above." }
}

# Get-CABSuggestedGroup — heuristic for placing a new repo into a manifest
# group based on naming conventions. Maintainer always has the final say;
# this is just a starting point so a 1-line eyeball + paste is realistic.
function Get-CABSuggestedGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Slug)
    $name = ($Slug -split '/')[-1]
    if ($name -like '.github*' -or $name -ieq 'Keystone') { return 'docs' }
    if ($name -like 'ca-*')                                { return 'ca-platform' }
    if ($name -like 'cm-*' -or $name -ieq 'channel-manager') { return 'cm-product' }
    return 'unsorted'
}
