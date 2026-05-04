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

    # Phase 2: welcome → workspace → folders → clone repos.
    # Phases 3-5 will insert tool-prereqs (20) and gh-auth (30) before workspace.
    $stepIds = @('10-welcome','40-workspace','50-folders','60-repos')
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
    Write-CABStatus -Status ok -Message 'Phase 2 complete: workspace + folders + repos.'
    Write-Host '    Phases 3-8 (tool detect/install, gh auth, git identity, extras) come next.'
    Write-Host ''
    Write-Host "  Transcript: $(Get-CABTranscriptPath)"
    Write-Host "  Journal   : $(Get-CABJournalPath)"
    return 0
}

# Function exported automatically when this file is dot-sourced.
