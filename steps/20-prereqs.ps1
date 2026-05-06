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

    Write-CABStep -Number ($Context.StepOrdinal ?? 2) -Total $Context.TotalSteps -Title 'Prerequisites'

    $detection = Test-CABStep20 -Context $Context
    Format-CABToolReport -Report $detection.report
    Write-Host ''

    $Context.PrereqReport = $detection.report
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/tools.yaml')
    $allTools = @($manifest.required) + @($manifest.optional)
    $byId = @{}
    foreach ($t in $allTools) { $byId[$t.id] = $t }

    $missing = @($detection.report | Where-Object { $_.status -in 'fail','warn' })
    if ($missing.Count -eq 0) {
        return @{ status = 'ok'; details = 'All tools present.' }
    }

    $choice = Read-CABChoice `
        -Question "Install $($missing.Count) missing/outdated tool(s)?" `
        -Options @(
            @{ Key = 'Y'; Label = 'Yes (install all)' },
            @{ Key = 's'; Label = 'Select individually' },
            @{ Key = 'n'; Label = 'Skip (install manually later)' }
        ) `
        -Default 'Y' `
        -AnswerKey 'prereqs.install_choice'

    if ($choice -eq 'quit') {
        return @{ status = 'quit'; details = 'User quit at prereqs step.' }
    }

    if ($choice -ieq 'n') {
        $missingRequired = @($missing | Where-Object { $_.is_required })
        if ($missingRequired.Count -gt 0) {
            return @{ status = 'fail'; details = "$($missingRequired.Count) required tool(s) missing — install and re-run." }
        }
        return @{ status = 'warn'; details = "$($missing.Count) optional tool(s) skipped." }
    }

    # Install loop.
    $installed = 0
    $skipped = 0
    $failed = New-Object System.Collections.Generic.List[string]

    foreach ($r in $missing) {
        $tool = $byId[$r.id]
        if (-not $tool) { continue }

        $shouldInstall = ($choice -ieq 'Y')
        if ($choice -ieq 's') {
            $heavyHint = if ($tool.heavy) { ' (heavy install)' } else { '' }
            $rebootHint = if ($tool.requires_reboot -and $tool.requires_reboot[(Get-CABOSFamily)]) {
                ' [requires reboot]'
            } elseif ($tool.requires_reboot -is [bool] -and $tool.requires_reboot) {
                ' [requires reboot]'
            } else { '' }
            $default = -not ($tool.heavy -or $tool.requires_reboot)
            $ans = Read-CABConfirm `
                -Question "Install $($tool.name)$heavyHint$rebootHint?" `
                -Default $default `
                -AnswerKey "prereqs.install.$($tool.id)"
            if (Test-CABQuit $ans) {
                return @{ status = 'quit'; details = 'User quit during install selection.' }
            }
            $shouldInstall = (Test-CABYes $ans)
        }

        if (-not $shouldInstall) {
            Write-CABStatus -Status skip -Message "$($tool.id) skipped"
            $skipped++
            continue
        }

        $result = Install-CABTool -Tool $tool -Context $Context
        if ($result.ok) {
            Write-CABStatus -Status ok -Message "$($tool.id) — $($result.details)"
            Add-CABJournalEntry -Step '20-prereqs' -Action 'install_tool' -Data @{
                tool   = $tool.id
                method = (Get-CABInstallEntry -Tool $tool).type
            } | Out-Null
            $installed++

            # Re-test to confirm.
            $recheck = Test-CABTool -Tool $tool
            if ($recheck.status -ne 'ok') {
                Write-CABColor Yellow "      ⓘ Post-install check still reports: $($recheck.details)"
            }
        } else {
            Write-CABStatus -Status fail -Message "$($tool.id) — $($result.details)"
            $failed.Add($tool.id)
        }
    }

    $summary = "$installed installed, $skipped skipped, $($failed.Count) failed"
    if ($failed.Count -gt 0) {
        $missingRequiredAfter = @($failed | Where-Object { ($byId[$_]).id -in @($manifest.required.id) })
        if ($missingRequiredAfter.Count -gt 0) {
            return @{ status = 'fail'; details = "$summary. Required failures: $($missingRequiredAfter -join ', ')" }
        }
        return @{ status = 'warn'; details = "$summary. Optional failures: $($failed -join ', ')" }
    }
    return @{ status = 'ok'; details = $summary }
}

function Undo-CABStep20 {
    @{ status = 'noop'; details = 'Tool installs reversed by undo --include-tools (phase 10).' }
}
