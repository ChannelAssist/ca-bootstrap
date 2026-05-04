#requires -Version 5.1
<#
.SYNOPSIS
ca-bootstrap one-line entrypoint for Windows.

.DESCRIPTION
Ensures pwsh 7+ and git are available, clones (or updates) the ca-bootstrap
repository to a cache directory, and hands off to ca-bootstrap.ps1 setup.

.EXAMPLE
iwr -useb https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.ps1 | iex
#>

[CmdletBinding()]
param(
    [string]$RepoUrl = $env:CA_BOOTSTRAP_REPO,
    [string]$RepoRef = $env:CA_BOOTSTRAP_REF,
    [string]$CacheDir = $env:CA_BOOTSTRAP_CACHE
)

if (-not $RepoUrl)  { $RepoUrl  = 'https://github.com/ChannelAssist/ca-bootstrap.git' }
if (-not $RepoRef)  { $RepoRef  = 'main' }
if (-not $CacheDir) { $CacheDir = Join-Path $HOME '.ca-bootstrap\cache' }

function Write-Color($Color, $Text) {
    $orig = [Console]::ForegroundColor
    [Console]::ForegroundColor = $Color
    Write-Host $Text
    [Console]::ForegroundColor = $orig
}

function Test-Command($Name) {
    [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-Pwsh {
    Write-Color Blue 'Installing PowerShell 7...'
    if (Test-Command 'winget') {
        winget install --id Microsoft.PowerShell --silent --accept-source-agreements --accept-package-agreements
    } else {
        Write-Color Red 'winget is not available. Install PowerShell 7 manually:'
        Write-Color Red '  https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows'
        exit 2
    }
    Write-Color Green '✓ PowerShell installed.'
}

function Install-Git {
    Write-Color Blue 'Installing git...'
    if (Test-Command 'winget') {
        winget install --id Git.Git --silent --accept-source-agreements --accept-package-agreements
    } else {
        Write-Color Red 'winget is not available. Install git manually and re-run.'
        exit 2
    }
    Write-Color Green '✓ git installed.'
}

Write-Color Blue 'ca-bootstrap — preparing your environment'
Write-Host ''

# Ensure pwsh 7+ (we may currently be in 5.1)
$pwshAvailable = Test-Command 'pwsh'
if (-not $pwshAvailable) {
    Write-Color Yellow 'PowerShell 7+ is not installed. ca-bootstrap requires it.'
    $ans = Read-Host 'Install now? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]') {
        Install-Pwsh
    } else {
        Write-Color Red 'Cannot continue without PowerShell 7. Exiting.'
        exit 1
    }
}

if (-not (Test-Command 'git')) {
    Write-Color Yellow 'git is not installed. ca-bootstrap requires it.'
    $ans = Read-Host 'Install now? [Y/n]'
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]') {
        Install-Git
    } else {
        Write-Color Red 'Cannot continue without git. Exiting.'
        exit 1
    }
}

if (-not (Test-Path $CacheDir)) {
    [void](New-Item -ItemType Directory -Path $CacheDir -Force)
}

if (Test-Path (Join-Path $CacheDir '.git')) {
    Write-Color Blue "Updating ca-bootstrap (cache: $CacheDir)..."
    git -C $CacheDir fetch --quiet origin $RepoRef 2>&1 | Out-Null
    $fetchExit = $LASTEXITCODE
    if ($fetchExit -ne 0) {
        # Fall back to a fresh clone if the cache is corrupt or git fails
        # (the most common cause is a malformed line in the user's global
        # .gitconfig, which makes every git command exit non-zero).
        Write-Color Yellow "Cache update failed (exit $fetchExit). Refreshing cache from scratch..."
        Remove-Item -Recurse -Force $CacheDir
        git clone --quiet --depth 1 --branch $RepoRef $RepoUrl $CacheDir
        if ($LASTEXITCODE -ne 0) {
            Write-Color Red "Re-clone also failed. Check your global .gitconfig for a malformed line, then retry."
            exit 1
        }
    } else {
        git -C $CacheDir checkout --quiet $RepoRef
        git -C $CacheDir pull --quiet --ff-only origin $RepoRef
    }
} else {
    Write-Color Blue "Fetching ca-bootstrap from $RepoUrl ($RepoRef)..."
    git clone --quiet --depth 1 --branch $RepoRef $RepoUrl $CacheDir
}
Write-Color Green '✓ ca-bootstrap ready.'
Write-Host ''

$caBootstrapPs1 = Join-Path $CacheDir 'ca-bootstrap.ps1'
& pwsh -NoLogo -File $caBootstrapPs1 setup
exit $LASTEXITCODE
