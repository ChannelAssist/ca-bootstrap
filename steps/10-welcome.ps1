#requires -Version 7.0
# steps/10-welcome.ps1 — explain scope, get consent.
#
# Each step exposes Test/Invoke/Undo. Phase 1 only implements the
# minimum needed for the welcome path. Steps 20-80 will follow in
# subsequent phases.

function Test-CABStep10 {
    [CmdletBinding()]
    param()
    # Welcome is informational. Always returns 'pending' on setup
    # (we want to show it once per session). Doctor never runs it.
    @{ status = 'pending'; details = 'Informational step — always shown.' }
}

function Invoke-CABStep10 {
    [CmdletBinding()]
    param([hashtable]$Context)

    $totalSteps = if ($Context.TotalSteps) { $Context.TotalSteps } else { 8 }
    Write-CABStep -Number ($Context.StepOrdinal ?? 1) -Total $totalSteps -Title 'Welcome'

    Write-Host '  This wizard will set up your machine for ChannelAssist development:'
    Write-Host '    • install missing tools (git, gh, .NET 10, Node 20, Python 3.12,'
    Write-Host '      Docker Desktop, VS Code, VS Code extensions, optionally WSL2)'
    Write-Host '    • authenticate to GitHub'
    Write-Host '    • create the workspace folder structure'
    Write-Host '    • clone the repos you have access to'
    Write-Host '    • configure your git identity for ChannelAssist commits'
    Write-Host ''
    Write-Host "  Every step is optional. Quit any time with Ctrl+C or 'q' at any prompt."
    Write-Host "  A transcript will be saved to $(Get-CABTranscriptPath)."
    Write-Host ''

    $proceed = Read-CABConfirm -Question 'Continue?' -Default $true -AnswerKey 'welcome.continue'
    if (Test-CABQuit $proceed) {
        return @{ status = 'quit'; details = 'User quit at welcome.' }
    }
    if (Test-CABNo $proceed) {
        return @{ status = 'quit'; details = 'User declined to continue.' }
    }
    @{ status = 'ok'; details = 'User consented to proceed.' }
}

function Undo-CABStep10 {
    # Welcome has no side effects — nothing to undo.
    @{ status = 'noop'; details = 'Informational step; nothing to reverse.' }
}

# Functions exported automatically when this file is dot-sourced.
