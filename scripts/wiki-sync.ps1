#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
ca-bootstrap wiki sync — Windows-native peer of scripts/wiki-sync.sh.

.DESCRIPTION
Mirror README + DESIGN.md + docs/ into the GitHub Wiki working tree, then
commit and push with the canonical ADR-013 retry-on-divergence pattern.

The push function follows the canonical ChannelAssist wiki-sync push
pattern defined in Keystone ADR 013 (which supersedes ADR 012). The
canonical handles concurrent-write divergence, detached-HEAD recovery,
and first-time push.

Reference: https://github.com/ChannelAssist/Keystone/blob/dev/content/docs/adr/013-wiki-sync-canonical-revised.md

.EXAMPLE
./scripts/wiki-sync.ps1 clone    # clone the wiki repo (one-time)
./scripts/wiki-sync.ps1 sync     # copy + transform docs into ./wiki
./scripts/wiki-sync.ps1 push     # commit + push (with retry-on-divergence)
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('clone', 'sync', 'push', 'full', 'help')]
    [string]$Command = 'help'
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot      = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:WikiDir       = Join-Path $script:RepoRoot 'wiki'
$script:WikiUrlHttps  = 'https://github.com/ChannelAssist/ca-bootstrap.wiki.git'
$script:SourceReadme  = Join-Path $script:RepoRoot 'README.md'
$script:SourceDesign  = Join-Path $script:RepoRoot 'DESIGN.md'
$script:SourceDocs    = Join-Path $script:RepoRoot 'docs'

function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Blue }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Msg) Write-Host "[ERR]  $Msg" -ForegroundColor Red }

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    & git @Arguments
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE)"
    }
    return $LASTEXITCODE
}

function Cmd-Clone {
    if (Test-Path (Join-Path $script:WikiDir '.git')) {
        Write-Warn2 "Wiki already cloned at $($script:WikiDir). Pulling latest..."
        Invoke-Git -Arguments @('-C', $script:WikiDir, 'pull', '--ff-only')
        return
    }
    Write-Info "Cloning $($script:WikiUrlHttps) to $($script:WikiDir)..."
    & git clone $script:WikiUrlHttps $script:WikiDir 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 'Wiki clone failed — the wiki may not be initialized yet.'
        Write-Warn2 'Visit https://github.com/ChannelAssist/ca-bootstrap/wiki and create the first page,'
        Write-Warn2 "then re-run './make.ps1 wiki-update'."
        exit 1
    }
    Write-Ok "Wiki cloned to $($script:WikiDir)"
}

function Transform-Links {
    param([Parameter(Mandatory)][string]$File)
    # Wiki pages live flat at the wiki root, so:
    #   ../DESIGN.md     → DESIGN.md
    #   ../README.md     → Home.md (README is rendered as Home)
    #   docs/foo.md      → foo.md
    #   ./foo.md         → foo.md
    $content = Get-Content -Raw -Path $File
    $content = $content -replace '\]\((?:\.{1,2}/)?docs/([^)]+\.md)\)', '](${1})'
    $content = $content -replace '\]\((?:\.\./)?DESIGN\.md\)', '](DESIGN.md)'
    $content = $content -replace '\]\((?:\.\./)?README\.md\)', '](Home.md)'
    Set-Content -Path $File -Value $content -NoNewline
}

function Cmd-Sync {
    if (-not (Test-Path (Join-Path $script:WikiDir '.git'))) {
        Write-Bad "Wiki not cloned. Run './scripts/wiki-sync.ps1 clone' first (or 'full' / './make.ps1 wiki-update' for the end-to-end flow)."
        exit 1
    }

    Write-Info 'Pulling latest wiki state...'
    Invoke-Git -Arguments @('-C', $script:WikiDir, 'fetch', '--quiet', 'origin')
    # Try origin/master first (older wikis), then origin/main. Mirror bash's
    # `2>/dev/null || ...` chain.
    & git -C $script:WikiDir reset --quiet --hard 'origin/master' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Git -Arguments @('-C', $script:WikiDir, 'reset', '--quiet', '--hard', 'origin/main')
    }

    Write-Info 'Cleaning destination...'
    # Delete every .md at the wiki root EXCEPT _Sidebar.md / _Footer.md (we
    # regenerate those ourselves below; deleting and re-emitting would just
    # churn the working tree).
    Get-ChildItem -Path $script:WikiDir -Filter '*.md' -File |
        Where-Object { $_.Name -notin @('_Sidebar.md', '_Footer.md') } |
        Remove-Item -Force

    # Drop every subdirectory except .git — wiki rendering is flat.
    Get-ChildItem -Path $script:WikiDir -Directory |
        Where-Object { $_.Name -ne '.git' } |
        Remove-Item -Recurse -Force

    Write-Info 'Copying README → Home.md...'
    Copy-Item -Path $script:SourceReadme -Destination (Join-Path $script:WikiDir 'Home.md') -Force

    Write-Info 'Copying DESIGN.md...'
    Copy-Item -Path $script:SourceDesign -Destination (Join-Path $script:WikiDir 'DESIGN.md') -Force

    Write-Info 'Copying docs/*.md flat into wiki root...'
    if (Test-Path $script:SourceDocs) {
        Get-ChildItem -Path $script:SourceDocs -Recurse -File -Filter '*.md' | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination (Join-Path $script:WikiDir $_.Name) -Force
        }
    }

    Write-Info 'Rewriting links for wiki rendering...'
    Get-ChildItem -Path $script:WikiDir -Filter '*.md' -File | ForEach-Object {
        Transform-Links -File $_.FullName
    }

    Write-Info 'Generating sidebar...'
    $sidebarLines = [System.Collections.Generic.List[string]]::new()
    $sidebarLines.Add('# ca-bootstrap')
    $sidebarLines.Add('')
    $sidebarLines.Add('- [[Home]]')
    $sidebarLines.Add('- [[DESIGN]]')
    $sidebarLines.Add('')
    $sidebarLines.Add('## Reference')
    Get-ChildItem -Path $script:WikiDir -Filter '*.md' -File |
        Sort-Object Name | ForEach-Object {
            $base = [IO.Path]::GetFileNameWithoutExtension($_.Name)
            if ($base -notin @('Home', 'DESIGN', '_Sidebar', '_Footer')) {
                $sidebarLines.Add("- [[$base]]")
            }
        }
    Set-Content -Path (Join-Path $script:WikiDir '_Sidebar.md') -Value ($sidebarLines -join "`n")

    Write-Info 'Stamping footer...'
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')
    # Footer text must match the bash peer (scripts/wiki-sync.sh) byte-for-byte
    # — this string is committed into the wiki and gets rewritten on every sync,
    # so any divergence between peers causes churn when sync runs from different
    # platforms.
    $footer = @"

---
*Last synced from ``main`` at $stamp UTC. Edit source under ``docs/`` and run ``make wiki-update`` (or ``./make.ps1 wiki-update`` on Windows).*
"@
    Set-Content -Path (Join-Path $script:WikiDir '_Footer.md') -Value $footer

    Write-Ok 'Wiki working tree synced.'
}

function Cmd-Push {
    if (-not (Test-Path (Join-Path $script:WikiDir '.git'))) {
        Write-Bad "Wiki not cloned. Run './scripts/wiki-sync.ps1 clone' first (or 'full' / './make.ps1 wiki-update' for the end-to-end flow)."
        exit 1
    }

    Push-Location $script:WikiDir
    try {
        $status = & git status --porcelain
        if ([string]::IsNullOrWhiteSpace($status)) {
            Write-Warn2 'No wiki changes to push.'
            return
        }

        Invoke-Git -Arguments @('add', '.')
        Invoke-Git -Arguments @('commit', '-m', 'Update wiki documentation from repository', '--quiet')

        # Push pattern per ADR 013: detached-HEAD-safe, retries on divergence.
        $branch = (& git branch --show-current).Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            $defaultBranch = & git symbolic-ref --short refs/remotes/origin/HEAD 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($defaultBranch)) {
                $defaultBranch = 'master'
            }
            else {
                $defaultBranch = $defaultBranch -replace '^origin/', ''
            }
            Write-Warn2 "HEAD is detached; checking out $defaultBranch at current commit"
            Invoke-Git -Arguments @('checkout', '-B', $defaultBranch)
        }

        & git push origin HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Wiki changes pushed.'
            return
        }

        & git push -u origin HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok 'Wiki changes pushed (set upstream).'
            return
        }

        Write-Warn2 'Push rejected (likely concurrent-write divergence); fetching and rebasing...'
        & git fetch --quiet origin 2>$null
        & git pull --rebase --quiet origin HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            & git push origin HEAD
            if ($LASTEXITCODE -eq 0) {
                Write-Ok 'Wiki changes pushed (after rebase).'
                return
            }
        }
        Write-Bad 'Wiki push failed — manual intervention required (see Keystone ADR 013).'
        exit 1
    }
    finally {
        Pop-Location
    }
}

function Cmd-Full {
    # Clones the wiki if absent, then delegates to Cmd-Sync (which owns the
    # fetch/reset) and Cmd-Push. The redundant fetch/reset that used to live
    # here was removed: Cmd-Sync already does a fetch+reset at its start, so
    # doing it twice created two separate reset-points — the second (in
    # Cmd-Sync) always wins, but the gap between them is a silent failure
    # surface. One place owns the pull.
    if (-not (Test-Path (Join-Path $script:WikiDir '.git'))) {
        Cmd-Clone
    }
    Cmd-Sync
    Cmd-Push
}

function Cmd-Help {
    Write-Host 'Usage: ./scripts/wiki-sync.ps1 {clone|sync|push|full}'
}

switch ($Command) {
    'clone' { Cmd-Clone }
    'sync'  { Cmd-Sync }
    'push'  { Cmd-Push }
    'full'  { Cmd-Full }
    'help'  { Cmd-Help }
    default {
        Write-Bad "Unknown command: $Command"
        Cmd-Help
        exit 1
    }
}
