#requires -Version 7.0
# commands/setup.ps1 — runs all steps in order, install/fix mode.
#
# Phase 1 wires only step 10 (welcome). Subsequent phases will append
# step 20…80 to the $stepIds list as they're implemented.

function Invoke-CABCommandSetup {
    [CmdletBinding()]
    param(
        [hashtable]$Context = @{}
    )

    # Phase 6: full setup happy path — eight steps, end to end.
    $stepIds = @(
        '10-welcome','20-prereqs','30-gh-auth','40-workspace',
        '50-folders','60-repos','70-git-identity','80-extras'
    )
    $Context.TotalSteps = 8   # display the eventual total so step numbering matches the design

    foreach ($stepId in $stepIds) {
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
                Write-CABStatus -Status info -Message 'You quit. Partial changes (if any) are recorded in the journal.'
                Save-CABJournal
                return 1
            }
            'fail'    {
                Write-CABStatus -Status fail -Message $result.details
                Save-CABJournal
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
