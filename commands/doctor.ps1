#requires -Version 7.0
# commands/doctor.ps1 — diagnostic-only run.
#
# Phase 3 wires the prerequisite tool detection from manifest/tools.yaml.
# Phase 8 will extend this with workspace/folder/repo/identity checks
# (the full "is my setup right?" report).

function Invoke-CABCommandDoctor {
    [CmdletBinding()]
    param([hashtable]$Context = @{})

    Write-CABHeader 'ca-bootstrap doctor'
    Write-Host ''

    Write-CABColor White 'Prerequisites'
    $report = Get-CABToolReport -ManifestPath (Join-Path $Context.RepoRoot 'manifest/tools.yaml')
    Format-CABToolReport -Report $report
    Write-Host ''

    $required = @($report | Where-Object { $_.is_required })
    $optional = @($report | Where-Object { -not $_.is_required })
    $reqFail  = @($required | Where-Object { $_.status -in 'fail','warn','error' })
    $optFail  = @($optional | Where-Object { $_.status -in 'fail','warn' })

    Write-CABColor White 'Workspace, folders, repos, identity'
    Write-CABStatus -Status info -Message 'Phase 8 deliverable — not yet implemented.'
    Write-Host ''

    Write-CABColor White 'Summary'
    if ($reqFail.Count -eq 0 -and $optFail.Count -eq 0) {
        Write-CABStatus -Status ok -Message 'All checks ✓'
        Write-Host ''
        return 0
    }
    if ($reqFail.Count -gt 0) {
        Write-CABStatus -Status fail -Message "$($reqFail.Count) required issue(s) found"
    }
    if ($optFail.Count -gt 0) {
        Write-CABStatus -Status warn -Message "$($optFail.Count) optional issue(s) found"
    }
    Write-Host ''
    Write-Host '  To fix:  ca-bootstrap.ps1 repair --all'
    Write-Host '  Or, e.g.: ca-bootstrap.ps1 repair --target dotnet-10'
    Write-Host ''

    if ($reqFail.Count -gt 0) { return 2 }
    return 2   # warnings also exit 2 per docs/commands.md
}
