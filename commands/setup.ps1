#requires -Version 7.0
# commands/setup.ps1 — runs all steps in order, install/fix mode.

# Invoke-CABQuitWithRollbackOffer — called when the user quits or a step
# fails. Offers to undo this session's recorded actions so the user
# doesn't have to manually clean up a half-set-up workspace. Reuses
# undo's per-action reversers.
function Invoke-CABQuitWithRollbackOffer {
    [CmdletBinding()]
    param(
        [hashtable]$Context,
        [string]$Reason = 'Quitting'
    )
    $actions = Get-CABCurrentSessionActions
    if ($actions.Count -eq 0) {
        Write-CABStatus -Status info -Message "$Reason. No actions recorded — nothing to roll back."
        return
    }

    Write-Host ''
    Write-CABColor Yellow "  $Reason. This session recorded $($actions.Count) action(s):"
    foreach ($a in ($actions | Select-Object -First 5)) {
        Write-Host "    • $($a.action)$(if ($a.path) { " — $($a.path)" } elseif ($a.repo) { " — $($a.repo)" })"
    }
    if ($actions.Count -gt 5) { Write-Host "    • … $($actions.Count - 5) more" }
    Write-Host ''

    $rollback = Read-CABConfirm `
        -Question 'Roll back the changes you made in this session?' `
        -Default $true `
        -AnswerKey 'quit.rollback'
    if (-not (Test-CABYes $rollback)) {
        Write-CABStatus -Status info -Message 'Leaving partial state in place. Run `ca-bootstrap.ps1 undo` later if you change your mind.'
        return
    }

    # Reuse undo's per-action reverser dispatch so we don't reimplement
    # any of the safety rules (uncommitted-changes guard, etc.). Per-
    # action [N/total] counter mirrors the install + clone progress
    # markers — long rollbacks now show where they are in the queue.
    . (Join-Path $Context.RepoRoot 'commands/undo.ps1')
    $reversed = 0
    $skipped = 0
    $progressIndex = 0
    $progressTotal = $actions.Count
    foreach ($entry in $actions) {
        $progressIndex++
        Write-Host '  ' -NoNewline
        Write-CABColor Cyan "[$progressIndex/$progressTotal]" -NoNewLine
        Write-CABColor DarkGray " reverting $($entry.action)..."
        $r = Invoke-CABUndoEntry -Entry $entry -Force:$false -IncludeFolders:$true -IncludeTools:$false -Context $Context
        switch ($r.status) {
            'ok'   { Mark-CABEntryUndone -EntryId $entry.id | Out-Null; $reversed++ }
            'noop' { Mark-CABEntryUndone -EntryId $entry.id | Out-Null; $skipped++ }
            default { $skipped++ }
        }
    }
    Save-CABJournal
    Write-Host ''
    Write-CABStatus -Status ok -Message "Rolled back $reversed action(s); $skipped skipped (kept by safety rules)."
}

# Single source of truth for the setup step list. Produces an ordered
# array of @{ id; title } hashtables used by both the orchestrator's
# main loop AND (via the welcome RPC event) the TUI's Tree pane. To
# rename or reorder a step, edit only this function.
function Get-CABSetupStepDefs {
    @(
        @{ id = '10-welcome';       title = 'Welcome' }
        @{ id = '40-workspace';     title = 'Workspace location' }
        @{ id = '20-prereqs';       title = 'Prerequisites' }
        @{ id = '30-gh-auth';       title = 'GitHub authentication' }
        @{ id = '50-folders';       title = 'Folder structure' }
        @{ id = '60-repos';         title = 'Clone repositories' }
        @{ id = '70-git-identity';  title = 'Git identity' }
        @{ id = '80-extras';        title = 'Optional extras' }
    )
}

function Invoke-CABCommandSetup {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{}
    )

    # Workspace location moved earlier in the flow so the user confirms
    # the destination directory BEFORE any tool installs, browser auth
    # flows, or other time-investment. Order:
    #   1. welcome    — explain + consent
    #   2. workspace  — confirm destination (the "where will this go?" question)
    #   3. prereqs    — detect + install missing tools
    #   4. gh-auth    — sign in to GitHub
    #   5. folders    — create the workspace skeleton
    #   6. repos      — clone
    #   7. identity   — per-folder git config
    #   8. extras     — VS Code workspace, plugin, WSL2
    # Single source of truth for step id → title mapping AND execution
    # order. To rename or reorder a step, edit only Get-CABSetupStepDefs.
    $stepDefs = Get-CABSetupStepDefs
    $Context.TotalSteps = $stepDefs.Count

    $ordinal = 0
    foreach ($stepDef in $stepDefs) {
        $stepId = $stepDef.id
        # Honor a Ctrl+C set during the previous step.
        if ($Script:CABQuitRequested) {
            Save-CABJournal
            Invoke-CABQuitWithRollbackOffer -Context $Context -Reason 'Ctrl+C received'
            return 1
        }
        $ordinal++
        $Context.StepOrdinal = $ordinal

        $stepPath = Join-Path $Context.RepoRoot "steps/$stepId.ps1"
        if (-not (Test-Path $stepPath)) {
            Write-CABStatus -Status fail -Message "Step file missing: $stepPath"
            return 99
        }
        . $stepPath

        $stepNum = ($stepId -split '-')[0]
        $invokeFn = "Invoke-CABStep$stepNum"

        $result = & $invokeFn -Context $Context

        switch ($result.status) {
            'ok'      { Write-CABStatus -Status ok   -Message $result.details }
            'skip'    { Write-CABStatus -Status skip -Message $result.details }
            'warn'    { Write-CABStatus -Status warn -Message $result.details }
            'quit'    {
                Save-CABJournal
                Invoke-CABQuitWithRollbackOffer -Context $Context -Reason 'You quit'
                return 1
            }
            'fail'    {
                Write-CABStatus -Status fail -Message $result.details
                Save-CABJournal
                Invoke-CABQuitWithRollbackOffer -Context $Context -Reason "Step '$stepId' failed"
                return 2
            }
            'pending' { Write-CABStatus -Status info -Message $result.details }
            default   { Write-CABStatus -Status warn -Message "Unknown step status: $($result.status)" }
        }
    }

    Save-CABJournal

    Write-Host ''
    Write-CABStatus -Status ok -Message 'Setup complete.'
    Write-Host '    `ca-bootstrap.ps1 doctor` — verify the result.'
    Write-Host '    `ca-bootstrap.ps1 repair --all` — fix anything doctor reports.'
    Write-Host '    `ca-bootstrap.ps1 undo` — reverse what was done.'
    Write-Host ''
    Write-Host "  Transcript: $(Get-CABTranscriptPath)"
    Write-Host "  Journal   : $(Get-CABJournalPath)"
    return 0
}

# Function exported automatically when this file is dot-sourced.
