#requires -Version 7.0
# commands/setup.ps1 — runs all steps in order, install/fix mode.
#
# Phase 1 wires only step 10 (welcome). Subsequent phases will append
# step 20…80 to the $stepIds list as they're implemented.

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
    # any of the safety rules (uncommitted-changes guard, etc.).
    . (Join-Path $Context.RepoRoot 'commands/undo.ps1')
    $reversed = 0
    $skipped = 0
    foreach ($entry in $actions) {
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
    $stepIds = @(
        '10-welcome','40-workspace','20-prereqs','30-gh-auth',
        '50-folders','60-repos','70-git-identity','80-extras'
    )
    $Context.TotalSteps = 8

    $ordinal = 0
    foreach ($stepId in $stepIds) {
        # Honor a Ctrl+C set during the previous step.
        if ($Script:CABQuitRequested) {
            Save-CABJournal
            Invoke-CABQuitWithRollbackOffer -Context $Context -Reason 'Ctrl+C received'
            return 1
        }
        $ordinal++
        $Context.StepOrdinal = $ordinal

        # When the TUI is driving, emit a step.start event before the
        # step runs and a step.end event after, so the Tree pane lights
        # up in real time. The step files themselves don't need to know.
        if ($Script:CABootstrapTuiMode) {
            $title = switch ($stepId) {
                '10-welcome'      { 'Welcome' }
                '20-prereqs'      { 'Prerequisites' }
                '30-gh-auth'      { 'GitHub authentication' }
                '40-workspace'    { 'Workspace location' }
                '50-folders'      { 'Folder structure' }
                '60-repos'        { 'Clone repositories' }
                '70-git-identity' { 'Git identity' }
                '80-extras'       { 'Optional extras' }
                default           { $stepId }
            }
            try {
                Send-CABTuiEvent -Event @{
                    type    = 'step'
                    phase   = 'start'
                    step    = $stepId
                    title   = $title
                    ordinal = $ordinal
                    total   = 8
                }
            } catch { }
        }
        $stepPath = Join-Path $Context.RepoRoot "steps/$stepId.ps1"
        if (-not (Test-Path $stepPath)) {
            Write-CABStatus -Status fail -Message "Step file missing: $stepPath"
            return 99
        }
        . $stepPath

        $stepNum = ($stepId -split '-')[0]
        $invokeFn = "Invoke-CABStep$stepNum"
        $result = & $invokeFn -Context $Context

        # Emit step.end mirroring the result. Done before the switch's
        # status-write so the TUI's Tree updates in lockstep with the CLI.
        if ($Script:CABootstrapTuiMode) {
            try {
                Send-CABTuiEvent -Event @{
                    type    = 'step'
                    phase   = if ($result.status -eq 'skip') { 'skip' } else { 'end' }
                    step    = $stepId
                    status  = $result.status
                    details = $result.details
                }
            } catch { }
        }

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
