#!/usr/bin/env pwsh
#requires -Version 5.1
<#
.SYNOPSIS
ca-bootstrap one-line entrypoint for Windows.

.DESCRIPTION
Two modes:

  1. Curl-pipe (the documented use): downloaded fresh, no sibling script
     present. Ensures pwsh 7+ and git are available, clones (or updates)
     the ca-bootstrap repository to a cache directory, then hands off to
     ca-bootstrap.ps1 setup.

  2. From a clone: a sibling `ca-bootstrap.ps1` exists next to this
     script. Skip the cache machinery entirely and forward all arguments
     directly to it. So `./bootstrap.ps1 doctor` from a clone behaves the
     same as `./ca-bootstrap.ps1 doctor`.

.EXAMPLE
iwr -useb https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.ps1 | iex

.EXAMPLE
./bootstrap.ps1 doctor                # from a clone — forwards to ca-bootstrap.ps1
#>

[CmdletBinding()]
param(
    [string]$RepoUrl = $env:CA_BOOTSTRAP_REPO,
    [string]$RepoRef = $env:CA_BOOTSTRAP_REF,
    [string]$CacheDir = $env:CA_BOOTSTRAP_CACHE,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

# Mode 2 short-circuit: if a sibling ca-bootstrap.ps1 is next to this
# script, we're inside a clone — just exec it with whatever the user
# typed. Skips cache fetch + git pull dance.
$selfDir  = $null
if ($MyInvocation.MyCommand.Path) { $selfDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$siblingOrch = if ($selfDir) { Join-Path $selfDir 'ca-bootstrap.ps1' } else { $null }
if ($siblingOrch -and (Test-Path $siblingOrch)) {
    # If the user invoked `./bootstrap.ps1 setup` (or doctor / repair /
    # undo), PowerShell positionally binds the first arg to $RepoUrl
    # rather than $ForwardArgs (since RepoUrl is declared first). Treat
    # a known-command string in $RepoUrl as the command to forward.
    $knownCommands = @('setup','doctor','repair','undo','help','--help','-h','version','--version')
    if ($RepoUrl -and ($knownCommands -contains $RepoUrl)) {
        $argsToForward = @($RepoUrl) + @($ForwardArgs)
    } elseif ($ForwardArgs -and $ForwardArgs.Count -gt 0) {
        $argsToForward = @($ForwardArgs)
    } else {
        $argsToForward = @('setup')
    }
    & pwsh -NoLogo -File $siblingOrch @argsToForward
    exit $LASTEXITCODE
}

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

# Optional: Python 3.10+ + cab-tui so the rich TUI is the default. Best
# effort — silent fallback to Read-Host if any step fails. CA_BOOTSTRAP_NO_TUI
# (any value) skips the install attempt entirely.
function Install-PythonAndTui {
    param([string]$Cache)
    if ($env:CA_BOOTSTRAP_NO_TUI) { return }
    if (-not $Cache -or -not (Test-Path $Cache)) { return }
    $cabTuiDir = Join-Path $Cache 'cab-tui'
    if (-not (Test-Path $cabTuiDir)) { return }   # older release without TUI

    # Find a usable Python 3.10+ on PATH.
    $py = $null
    foreach ($cand in 'python3','python','py') {
        if (Test-Command $cand) {
            $verLine = & $cand -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>$null
            if ($verLine -match '^(\d+)\.(\d+)$') {
                $major = [int]$Matches[1]; $minor = [int]$Matches[2]
                if ($major -ge 3 -and $minor -ge 10) { $py = $cand; break }
            }
        }
    }

    if (-not $py) {
        Write-Color Yellow 'Python 3.10+ not found — skipping cab-tui install (legacy CLI will be used).'
        if (Test-Command 'winget') {
            Write-Color Yellow '  Optional: `winget install Python.Python.3.12` then re-run to enable the TUI.'
        }
        return
    }

    # Already importable? Nothing to do.
    & $py -m cab_tui --check 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Color Green '✓ cab-tui already installed.'
        return
    }

    Write-Color Blue 'Installing cab-tui (optional rich TUI front-end)...'
    & $py -m pip install --quiet --upgrade pip 2>$null | Out-Null
    & $py -m pip install --quiet -e $cabTuiDir 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Color Green '✓ cab-tui installed; setup will auto-launch the TUI.'
    } else {
        Write-Color Yellow '  cab-tui install failed; continuing with the legacy Read-Host CLI.'
        Write-Color Yellow '  (Set CA_BOOTSTRAP_NO_TUI=1 to silence this message.)'
    }
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

# Best-effort cab-tui install so the rich TUI is the default for new users.
Install-PythonAndTui -Cache $CacheDir
Write-Host ''

$caBootstrapPs1 = Join-Path $CacheDir 'ca-bootstrap.ps1'
& pwsh -NoLogo -File $caBootstrapPs1 setup
exit $LASTEXITCODE
