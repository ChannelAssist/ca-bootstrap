#requires -Version 7.0
# commands/repos-drift.ps1 — detect drift between manifest/repos.yaml and GitHub org.
#
# Compares repos listed in manifest/repos.yaml against the actual repos in the
# ChannelAssist GitHub org. Reports:
#   - Repos in manifest but not in org (may be deleted, renamed, or archived)
#   - Repos in org but not in manifest (new repos that should be added)
#
# Exit codes:
#   0   no drift detected
#   2   drift detected (repos missing or extra)
#  99   unexpected error

function Invoke-CABCommandReposDrift {
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [switch]$IncludeArchived,
        [switch]$Json
    )

    $manifestPath = Join-Path $Context.RepoRoot 'manifest/repos.yaml'

    if (-not (Test-Path $manifestPath)) {
        Write-CABColor Red "✗ Manifest not found: $manifestPath"
        return 99
    }

    try {
        $comparison = Compare-CABRepoManifest -ManifestPath $manifestPath -Org 'ChannelAssist'

        if ($comparison.error) {
            Write-CABColor Red "✗ $($comparison.error)"
            return 99
        }

        if ($Json) {
            # Output JSON format for scripting/CI
            $result = @{
                schema_version = 1
                timestamp = (Get-Date -Format 'o')
                drift_detected = -not $comparison.ok
                manifest_repo_count = $comparison.manifestRepoCount
                org_repo_count = $comparison.orgRepoCount
                in_manifest_not_in_org = $comparison.inManifestNotInOrg
                in_org_not_in_manifest = $comparison.inOrgNotInManifest
            }
            Write-Host ($result | ConvertTo-Json -Depth 10)
        } else {
            # Human-readable format
            Format-CABReposDriftReport -Comparison $comparison
        }

        # Exit code: 0 if no drift, 2 if drift detected
        return ($comparison.ok ? 0 : 2)

    } catch {
        Write-CABColor Red "✗ Unexpected error: $($_.Exception.Message)"
        Write-Host $_.ScriptStackTrace
        return 99
    }
}
