#requires -Version 7.0
# lib/repos-drift.ps1 — drift detection for manifest/repos.yaml vs GitHub org.

# Get-CABOrgRepos — fetch all non-archived repos from the ChannelAssist org via gh CLI.
# Returns an array of repo slugs (org/name) or empty array on failure.
function Get-CABOrgRepos {
    [CmdletBinding()]
    param(
        [Parameter()][string]$Org = 'ChannelAssist',
        [Parameter()][switch]$IncludeArchived
    )

    if (-not (Test-CABCommandAvailable 'gh')) {
        Write-CABColor Red '  gh CLI not installed'
        return @()
    }

    if (-not (Test-CABGhAuth)) {
        Write-CABColor Red '  gh not authenticated. Run: gh auth login'
        return @()
    }

    Write-CABColor Gray "  Fetching repos from $Org org..."

    # Use gh repo list to get all repos in the org
    # Format: org/name
    $args = @('repo', 'list', $Org, '--limit', '1000', '--json', 'nameWithOwner,isArchived')
    $output = & gh @args 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-CABColor Red "  Failed to fetch repos: $($output -join "`n")"
        return @()
    }

    try {
        $repos = $output | ConvertFrom-Json
        $filtered = if ($IncludeArchived) {
            $repos
        } else {
            $repos | Where-Object { -not $_.isArchived }
        }
        return @($filtered | ForEach-Object { $_.nameWithOwner })
    } catch {
        Write-CABColor Red "  Failed to parse gh output: $($_.Exception.Message)"
        return @()
    }
}

# Compare-CABRepoManifest — compare manifest/repos.yaml against GitHub org.
# Returns @{ inManifestNotInOrg = @(); inOrgNotInManifest = @(); ok = $bool }.
function Compare-CABRepoManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter()][string]$Org = 'ChannelAssist'
    )

    if (-not (Test-Path $ManifestPath)) {
        throw "Manifest not found: $ManifestPath"
    }

    # Read manifest
    $manifest = Read-CABManifest -Path $ManifestPath
    $manifestRepos = @($manifest.groups | ForEach-Object { $_.repos } | ForEach-Object { $_.repo })

    # Get org repos
    $orgRepos = @(Get-CABOrgRepos -Org $Org)

    if ($orgRepos.Count -eq 0) {
        Write-CABColor Yellow '  Warning: No repos fetched from org (gh auth issue?)'
        return @{
            ok = $false
            inManifestNotInOrg = @()
            inOrgNotInManifest = @()
            error = 'Failed to fetch org repos'
        }
    }

    # Compare
    $inManifestNotInOrg = @($manifestRepos | Where-Object { $_ -notin $orgRepos })
    $inOrgNotInManifest = @($orgRepos | Where-Object { $_ -notin $manifestRepos })

    return @{
        ok = ($inManifestNotInOrg.Count -eq 0 -and $inOrgNotInManifest.Count -eq 0)
        inManifestNotInOrg = $inManifestNotInOrg
        inOrgNotInManifest = $inOrgNotInManifest
        manifestRepoCount = $manifestRepos.Count
        orgRepoCount = $orgRepos.Count
    }
}

# Format-CABReposDriftReport — render drift comparison in human-readable format.
function Format-CABReposDriftReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Comparison
    )

    if ($Comparison.error) {
        Write-CABColor Red "✗ Error: $($Comparison.error)"
        return
    }

    Write-CABHeader 'Repository Drift Report'
    Write-Host ''

    if ($Comparison.ok) {
        Write-CABColor Green "✓ No drift detected"
        Write-Host "  Manifest: $($Comparison.manifestRepoCount) repos"
        Write-Host "  GitHub org: $($Comparison.orgRepoCount) repos"
        Write-Host ''
        return
    }

    Write-CABColor Yellow "⚠ Drift detected"
    Write-Host "  Manifest: $($Comparison.manifestRepoCount) repos"
    Write-Host "  GitHub org: $($Comparison.orgRepoCount) repos"
    Write-Host ''

    if ($Comparison.inManifestNotInOrg.Count -gt 0) {
        Write-CABColor Red "In manifest but not in GitHub org ($($Comparison.inManifestNotInOrg.Count)):"
        foreach ($repo in $Comparison.inManifestNotInOrg) {
            Write-Host "  • $repo"
        }
        Write-Host ''
        Write-CABColor Gray 'These repos may have been:'
        Write-Host '  - Deleted'
        Write-Host '  - Renamed (check GitHub org for similar names)'
        Write-Host '  - Archived (use --include-archived to see archived repos)'
        Write-Host '  - Transferred to another org'
        Write-Host ''
        Write-CABColor Yellow 'Action: Remove these entries from manifest/repos.yaml'
        Write-Host ''
    }

    if ($Comparison.inOrgNotInManifest.Count -gt 0) {
        Write-CABColor Yellow "In GitHub org but not in manifest ($($Comparison.inOrgNotInManifest.Count)):"
        foreach ($repo in $Comparison.inOrgNotInManifest) {
            Write-Host "  • $repo"
        }
        Write-Host ''
        Write-CABColor Gray 'These are repos that exist but are not tracked in the manifest.'
        Write-Host 'Action: Add entries to manifest/repos.yaml if they should be cloned by setup.'
        Write-Host ''
    }

    # Provide a template for adding new repos
    if ($Comparison.inOrgNotInManifest.Count -gt 0) {
        Write-CABColor Cyan 'Template for adding to manifest/repos.yaml:'
        Write-Host ''
        foreach ($repo in $Comparison.inOrgNotInManifest) {
            $name = $repo.Split('/')[1]
            Write-Host "  - { repo: $repo, into: <group>/$name, branch: main }"
        }
        Write-Host ''
    }
}
