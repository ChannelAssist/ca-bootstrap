#requires -Version 7.0
# lib/git-ops.ps1 — git/gh helpers used by the repos step.

# Test-CABCommandAvailable — quick check; returns true if the named
# executable resolves on PATH.
function Test-CABCommandAvailable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Test-CABGhAuth — true if `gh auth status` succeeds (i.e. user is logged in).
function Test-CABGhAuth {
    if (-not (Test-CABCommandAvailable 'gh')) { return $false }
    & gh auth status 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Test-CABRepoCloned — true if $Path is an existing git repo whose origin
# matches $ExpectedRepo (e.g. "ChannelAssist/Keystone"). Returns one of:
#   'absent'   — directory doesn't exist
#   'matches'  — directory exists, is a git repo, origin matches
#   'mismatch' — directory exists but is not a git repo, or origin differs
function Test-CABRepoCloned {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedRepo
    )
    if (-not (Test-Path $Path)) { return 'absent' }
    if (-not (Test-Path (Join-Path $Path '.git'))) { return 'mismatch' }
    $origin = & git -C $Path remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $origin) { return 'mismatch' }
    # Normalize: strip trailing .git and protocol prefix
    $normalized = $origin -replace '^https?://github\.com/', '' -replace '^git@github\.com:', '' -replace '\.git$', ''
    if ($normalized -ieq $ExpectedRepo) { return 'matches' }
    return 'mismatch'
}

# Invoke-CABRepoClone — clone $Repo into $Into, optionally checkout $Branch.
# Returns @{ ok = $bool; details = '...' }.
function Invoke-CABRepoClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Into,
        [string]$Branch
    )
    $parent = Split-Path -Parent $Into
    if (-not (Test-Path $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }

    # `file://` URLs (used by integration tests with local fixture repos)
    # bypass gh and use plain git, so tests don't need gh auth.
    if ($Repo -like 'file://*' -or $Repo -like '/*' -or $Repo -match '^[A-Za-z]:[\\/]') {
        $output = & git clone $Repo $Into 2>&1
    } else {
        if (-not (Test-CABCommandAvailable 'gh')) {
            return @{ ok = $false; details = 'gh CLI not installed' }
        }
        $output = & gh repo clone $Repo $Into 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        return @{ ok = $false; details = ($output -join "`n") }
    }
    if ($Branch) {
        $checkout = & git -C $Into checkout $Branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ ok = $true; details = "Cloned, but failed to checkout $Branch — staying on default. ($($checkout -join '; '))" }
        }
    }
    return @{ ok = $true; details = "Cloned to $Into" }
}

# Invoke-CABRepoFetch — git fetch on an existing clone (idempotent re-run).
function Invoke-CABRepoFetch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $output = & git -C $Path fetch --quiet 2>&1
    if ($LASTEXITCODE -ne 0) { return @{ ok = $false; details = ($output -join "`n") } }
    return @{ ok = $true; details = 'fetched' }
}

# Functions exported automatically when this file is dot-sourced.
