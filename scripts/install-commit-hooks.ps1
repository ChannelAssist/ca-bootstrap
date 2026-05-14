#requires -Version 7.0
<#
.SYNOPSIS
Install commitlint commit-msg hooks in cloned ChannelAssist repos.

.DESCRIPTION
Walks the workspace, finds every clone that has a commitlint config
(`commitlint.config.{js,mjs,cjs,ts}` or a `commitlint` key in
package.json), and installs `.git/hooks/commit-msg` that runs
`npx commitlint --edit "$1"`.

The hook lets `git commit` reject a non-conforming message LOCALLY,
catching e.g. a 78-char header before CI does. This is the "eat the
canonical's own dog food" item from the meta-bug followup in the
2026-05-12 Daily Report (commitlint canonical PR #41, where the
PR codifying the 72-char rule had a 78-char commit header).

Idempotent — re-running on an already-hooked repo is a no-op (the
existing hook is preserved if it already invokes commitlint).

.PARAMETER WorkspacePath
The directory to scan. Defaults to ~/ChannelAssist on macOS/Linux,
$env:USERPROFILE\ChannelAssist on Windows, matching the wizard's
default workspace.

.PARAMETER WhatIf
Show what would change without modifying anything.

.PARAMETER Force
Overwrite existing commit-msg hooks even if they don't invoke
commitlint. Default behavior preserves existing hooks (best-effort
non-destructive merge — see notes in the code).

.EXAMPLE
./scripts/install-commit-hooks.ps1

.EXAMPLE
./scripts/install-commit-hooks.ps1 -WorkspacePath ~/my-workspace -WhatIf

.EXAMPLE
./scripts/install-commit-hooks.ps1 -Force

.NOTES
Requires Node.js + npx on PATH. The wizard's step 20 (prereqs) and
step 80 (extras) ensure Node is installed; this script only sets up
the hooks and assumes Node is already present.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath = $null,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $WorkspacePath) {
    $WorkspacePath = if ($IsWindows) {
        Join-Path $env:USERPROFILE 'ChannelAssist'
    } else {
        Join-Path $HOME 'ChannelAssist'
    }
}

if (-not (Test-Path $WorkspacePath)) {
    Write-Error "Workspace not found: $WorkspacePath"
    exit 1
}

$HOOK_BODY = @'
#!/usr/bin/env sh
# Installed by ca-bootstrap/scripts/install-commit-hooks.ps1
# Runs commitlint locally so a non-conforming header (e.g. >72 chars)
# is rejected at `git commit` time, not at PR CI time.
# Skips if npx isn't on PATH (graceful — keep the commit flow working
# even on a partial dev-env setup).
if ! command -v npx >/dev/null 2>&1; then
  echo "[commit-msg] npx not on PATH; skipping commitlint check." >&2
  exit 0
fi
exec npx --no-install commitlint --edit "$1"
'@

function Test-HasCommitlintConfig {
    param([string]$RepoDir)
    foreach ($name in @(
        'commitlint.config.js',
        'commitlint.config.mjs',
        'commitlint.config.cjs',
        'commitlint.config.ts',
        '.commitlintrc',
        '.commitlintrc.js',
        '.commitlintrc.json',
        '.commitlintrc.yml',
        '.commitlintrc.yaml'
    )) {
        if (Test-Path (Join-Path $RepoDir $name)) { return $true }
    }
    # Also check package.json for a `commitlint` key
    $pkg = Join-Path $RepoDir 'package.json'
    if (Test-Path $pkg) {
        try {
            $obj = Get-Content $pkg -Raw | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'commitlint') { return $true }
        } catch {
            # Malformed package.json — ignore, don't crash the sweep
        }
    }
    return $false
}

function Test-HookIsOurs {
    param([string]$HookPath)
    if (-not (Test-Path $HookPath)) { return $false }
    $first200 = (Get-Content $HookPath -Raw -ErrorAction SilentlyContinue) -replace '`r',''
    if ([string]::IsNullOrEmpty($first200)) { return $false }
    # Marker line identifies our installed hook.
    return $first200 -match 'Installed by ca-bootstrap/scripts/install-commit-hooks\.ps1'
}

function Test-HookInvokesCommitlint {
    param([string]$HookPath)
    if (-not (Test-Path $HookPath)) { return $false }
    $content = Get-Content $HookPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return $false }
    return $content -match 'commitlint'
}

$stats = [ordered]@{
    Scanned   = 0
    NoConfig  = 0
    NoGit     = 0
    Installed = 0
    Updated   = 0
    Skipped   = 0
    Preserved = 0
}

Write-Host "Scanning $WorkspacePath for ChannelAssist clones with commitlint configured..." -ForegroundColor Cyan
Write-Host ""

# Two levels deep: <workspace>/<group>/<repo>
Get-ChildItem -Path $WorkspacePath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $groupDir = $_.FullName
    Get-ChildItem -Path $groupDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $repoDir = $_.FullName
        $stats.Scanned++

        if (-not (Test-Path (Join-Path $repoDir '.git'))) {
            $stats.NoGit++
            return
        }
        if (-not (Test-HasCommitlintConfig -RepoDir $repoDir)) {
            $stats.NoConfig++
            return
        }

        $hooksDir = Join-Path $repoDir '.git/hooks'
        $hookPath = Join-Path $hooksDir 'commit-msg'
        $rel = Resolve-Path -Relative $repoDir -ErrorAction SilentlyContinue
        if (-not $rel) { $rel = $repoDir }

        $action = $null
        if (Test-HookIsOurs -HookPath $hookPath) {
            # Our hook already installed; refresh its body in case content changed.
            $action = if ((Get-Content $hookPath -Raw) -ne $HOOK_BODY) { 'Updated' } else { 'Skipped' }
        } elseif (Test-Path $hookPath) {
            # Foreign hook exists — preserve it unless -Force.
            if ($Force) {
                $action = 'Updated'
            } else {
                Write-Host "  [preserve] $rel — existing commit-msg hook not ours; use -Force to overwrite" -ForegroundColor Yellow
                $stats.Preserved++
                return
            }
        } else {
            $action = 'Installed'
        }

        if ($PSCmdlet.ShouldProcess($hookPath, $action.ToLower())) {
            New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
            Set-Content -Path $hookPath -Value $HOOK_BODY -NoNewline
            if (-not $IsWindows) { chmod +x $hookPath }
            Write-Host "  [$($action.ToLower())] $rel" -ForegroundColor Green
            $stats."$action"++
        }
    }
}

Write-Host ""
Write-Host "Summary:" -ForegroundColor Cyan
foreach ($k in $stats.Keys) {
    Write-Host ("  {0,-10} {1}" -f $k, $stats[$k])
}

if ($stats.Installed -gt 0 -or $stats.Updated -gt 0) {
    Write-Host ""
    Write-Host "Done. New commits in those repos will run commitlint locally." -ForegroundColor Green
    Write-Host "If npx isn't on PATH the hook no-ops gracefully (see hook body)." -ForegroundColor DarkGray
}
