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

    $stepIds = @('10-welcome')   # phase 1: welcome only.
    $Context.TotalSteps = $stepIds.Count

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
            'ok'      { Write-CABStatus -Status ok      -Message $result.details }
            'skip'    { Write-CABStatus -Status skip    -Message $result.details }
            'quit'    {
                Write-CABStatus -Status info -Message 'You quit. No changes made.'
                return 1
            }
            'fail'    {
                Write-CABStatus -Status fail -Message $result.details
                return 2
            }
            'pending' { Write-CABStatus -Status info -Message $result.details }
            default   { Write-CABStatus -Status warn -Message "Unknown step status: $($result.status)" }
        }
    }

    Write-Host ''
    Write-CABStatus -Status ok -Message "Phase 1 complete. Steps 20-80 will be added in subsequent phases."
    Write-Host ''
    Write-Host "  Transcript: $(Get-CABTranscriptPath)"
    Write-Host "  Journal   : $(Get-CABJournalPath)"
    return 0
}

# Function exported automatically when this file is dot-sourced.
