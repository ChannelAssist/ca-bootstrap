#requires -Version 7.0
# steps/30-gh-auth.ps1 — ensure the user is authenticated to GitHub via gh CLI.

function Test-CABStep30 {
    [CmdletBinding()]
    param([hashtable]$Context)
    # Test-mode seam: pretend the user is logged in as the supplied name.
    if ($Context -and $Context.TestMode -and $Context.TestGhUser) {
        return @{ status = 'ok'; details = "Logged in as $($Context.TestGhUser) (TEST MODE stub)"; user = $Context.TestGhUser }
    }
    if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
        return @{ status = 'fail'; details = 'gh CLI not installed (install in step 20).' }
    }
    & gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $user = (& gh api user --jq .login 2>$null) -join ''
        return @{ status = 'ok'; details = "Logged in as $user"; user = $user }
    }
    return @{ status = 'pending'; details = 'Not authenticated to GitHub.' }
}

function Invoke-CABStep30 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number 3 -Total $Context.TotalSteps -Title 'GitHub authentication'

    $detection = Test-CABStep30 -Context $Context

    if ($detection.status -eq 'fail') {
        return @{ status = 'fail'; details = $detection.details }
    }

    if ($detection.status -eq 'ok') {
        return @{ status = 'skip'; details = $detection.details }
    }

    Write-Host '  You are not signed in to gh CLI. The browser device flow will'
    Write-Host '  open a tab where you can sign in to GitHub.'
    Write-Host '  HTTPS protocol is recommended (works on every platform without'
    Write-Host '  SSH key setup).'
    Write-Host ''

    $proceed = Read-CABConfirm -Question 'Run `gh auth login` now?' -Default $true -AnswerKey 'gh-auth.login'
    if ($proceed -is [string] -and $proceed -eq 'quit') {
        return @{ status = 'quit'; details = 'User quit at gh auth step.' }
    }
    if ($proceed -is [bool] -and -not $proceed) {
        return @{ status = 'fail'; details = 'gh auth required for repo cloning. Re-run setup after `gh auth login`.' }
    }

    if ($Context.WhatIfMode) {
        Write-CABStatus -Status info -Message 'WhatIf: would run `gh auth login --git-protocol https --web`'
        return @{ status = 'ok'; details = 'WhatIf: gh auth would be triggered.' }
    }

    & gh auth login --git-protocol https --web
    if ($LASTEXITCODE -ne 0) {
        return @{ status = 'fail'; details = "gh auth login exited $LASTEXITCODE" }
    }

    $user = (& gh api user --jq .login 2>$null) -join ''
    Add-CABJournalEntry -Step '30-gh-auth' -Action 'gh_auth_login' -Data @{
        protocol = 'https'
        user     = $user
    } | Out-Null

    return @{ status = 'ok'; details = "Logged in as $user" }
}

function Undo-CABStep30 {
    @{ status = 'noop'; details = 'Reversed by undo via `gh auth logout`.' }
}
