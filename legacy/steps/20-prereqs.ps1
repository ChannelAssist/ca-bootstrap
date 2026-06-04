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

    # Install loop. Per-tool [N/total] counter so the user can see
    # progress through a long install list — package managers don't
    # expose machine-readable progress, but at least the wizard can
    # say where it is in the queue.
    $installed = 0
    $skipped = 0
    $failed = New-Object System.Collections.Generic.List[hashtable]
    $progressIndex = 0
    $progressTotal = $missing.Count

    # Initialize the failed-tools list so the final setup summary in
    # commands/setup.ps1 can surface them. Step 20 is the only writer
    # today; the list is initialized defensively so the summary code
    # can read it unconditionally without a key-existence check.
    if (-not $Context.ContainsKey('FailedTools')) { $Context.FailedTools = @() }

    foreach ($r in $missing) {
        $progressIndex++
        $progressPrefix = "[$progressIndex/$progressTotal]"
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
                -Question "$progressPrefix Install $($tool.name)$($heavyHint)$($rebootHint)?" `
                -Default $default `
                -AnswerKey "prereqs.install.$($tool.id)"
            if (Test-CABQuit $ans) {
                return @{ status = 'quit'; details = 'User quit during install selection.' }
            }
            $shouldInstall = (Test-CABYes $ans)
        }

        if (-not $shouldInstall) {
            Write-CABStatus -Status skip -Prefix $progressPrefix -Message "$($tool.id) skipped"
            $skipped++
            continue
        }

        # Cyan prefix for visual prominence; rest stays dim so it doesn't
        # compete with the post-install ✓/✗ status line that follows.
        # Both segments go through Write-CABColor so NO_COLOR is honored
        # (Copilot review, PR #17).
        Write-Host '  ' -NoNewline
        Write-CABColor Cyan $progressPrefix -NoNewLine
        Write-CABColor DarkGray " Installing $($tool.name)..."
        $result = Install-CABTool -Tool $tool -Context $Context
        if ($result.ok) {
            Write-CABStatus -Status ok -Prefix $progressPrefix -Message "$($tool.id) — $($result.details)"
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
            Write-CABStatus -Status fail -Prefix $progressPrefix -Message "$($tool.id) — $($result.details)"
            $entry = @{ id = $tool.id; required = [bool]($tool.id -in @($manifest.required.id)); details = $result.details }
            $failed.Add($entry)
            $Context.FailedTools += $entry
            # Hint inline so the user understands the wizard isn't stopping.
            $hint = if ($entry.required) {
                'required tool — setup will continue; rerun `ca-bootstrap.ps1 repair --target {0}` after fixing the root cause.'
            } else {
                'optional tool — setup continues without it.'
            }
            Write-Host ("      → " + ($hint -f $tool.id)) -ForegroundColor DarkGray
        }
    }

    $summary = "$installed installed, $skipped skipped, $($failed.Count) failed"
    if ($failed.Count -gt 0) {
        # Previously, required failures returned status='fail' which aborted
        # the wizard with a rollback offer. Per the "don't bork on failure"
        # directive, we now downgrade to 'warn' so the user gets through
        # the rest of setup (gh auth, folders, clones) and sees a single
        # actionable summary at the end. The orchestrator's final summary
        # surfaces the per-tool `repair --target X` commands.
        $req = @($failed | Where-Object { $_.required } | ForEach-Object { $_.id })
        $opt = @($failed | Where-Object { -not $_.required } | ForEach-Object { $_.id })
        $parts = @()
        if ($req.Count -gt 0) { $parts += "Required failures: $($req -join ', ')" }
        if ($opt.Count -gt 0) { $parts += "Optional failures: $($opt -join ', ')" }
        return @{ status = 'warn'; details = "$summary. $($parts -join '; ')" }
    }
    return @{ status = 'ok'; details = $summary }
}

function Undo-CABStep20 {
    @{ status = 'noop'; details = 'Tool installs reversed by undo --include-tools (phase 10).' }
}
