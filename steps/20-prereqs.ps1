#requires -Version 7.0
# steps/20-prereqs.ps1 — detect installed tools; install in phase 4.

function Test-CABStep20 {
    [CmdletBinding()]
    param([hashtable]$Context)
    $report = Get-CABToolReport -ManifestPath (Join-Path $Context.RepoRoot 'manifest/tools.yaml')
    $missingRequired = @($report | Where-Object { $_.is_required -and $_.status -ne 'ok' })
    $issuesOptional  = @($report | Where-Object { -not $_.is_required -and $_.status -in 'warn','fail' })

    if ($missingRequired.Count -gt 0) {
        return @{
            status  = 'fail'
            details = "$($missingRequired.Count) required tool(s) missing/outdated"
            report  = $report
        }
    }
    if ($issuesOptional.Count -gt 0) {
        return @{
            status  = 'warn'
            details = "$($issuesOptional.Count) optional tool(s) missing/outdated"
            report  = $report
        }
    }
    return @{ status = 'ok'; details = 'All tools present.'; report = $report }
}

function Invoke-CABStep20 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number 2 -Total $Context.TotalSteps -Title 'Prerequisites'

    $detection = Test-CABStep20 -Context $Context
    Format-CABToolReport -Report $detection.report
    Write-Host ''

    # Phase 3 surfaces the report and lets the user choose to continue.
    # Phase 4 will offer to install missing tools here.
    $Context.PrereqReport = $detection.report

    $missingRequired = @($detection.report | Where-Object { $_.is_required -and $_.status -ne 'ok' })

    if ($missingRequired.Count -gt 0) {
        Write-CABColor Yellow "  $($missingRequired.Count) required tool(s) missing. Installation lands in phase 4."
        Write-Host '    For now, install them manually and re-run setup, or continue and skip steps that need them.'
        $proceed = Read-CABConfirm -Question 'Continue anyway?' -Default $false -AnswerKey 'prereqs.continue_with_missing'
        if ($proceed -is [string] -and $proceed -eq 'quit') {
            return @{ status = 'quit'; details = 'User quit at prereqs step.' }
        }
        if ($proceed -is [bool] -and -not $proceed) {
            return @{ status = 'fail'; details = "$($missingRequired.Count) required tool(s) missing — install and re-run." }
        }
    }

    return @{ status = 'ok'; details = 'Prerequisite report shown.' }
}

function Undo-CABStep20 {
    @{ status = 'noop'; details = 'Tool installs reversed by undo --include-tools (phase 10).' }
}
