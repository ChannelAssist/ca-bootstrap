#requires -Version 7.0
<#
.SYNOPSIS
Install commitlint commit-msg hooks in cloned ChannelAssist repos.

.DESCRIPTION
Walks the workspace, finds every clone that has a commitlint config
(`commitlint.config.{js,mjs,cjs,ts}`, `.commitlintrc[.{js,mjs,cjs,ts,
json,yml,yaml}]`, or a `commitlint` key in package.json), and installs
`.git/hooks/commit-msg` that runs `npx --no-install commitlint --edit "$1"`.

The hook lets `git commit` reject a non-conforming message LOCALLY,
catching e.g. a 78-char header before CI does. This is the "eat the
canonical's own dog food" item from the meta-bug followup in the
2026-05-12 Daily Report (commitlint canonical PR #41, where the PR
codifying the 72-char rule had a 78-char commit header).

Idempotent — re-running on an already-hooked repo refreshes the body
in place. Foreign commit-msg hooks are preserved unless `-Force`,
EXCEPT when the foreign hook already invokes commitlint (treated as
"good enough" — preserved with a different log line).

Both flat and 2-level workspace layouts are supported: each top-level
directory under `-WorkspacePath` is treated as a repo if it has a
`.git/` directly, otherwise the script descends one more level.

.PARAMETER WorkspacePath
The directory to scan. Defaults to ~/ChannelAssist on macOS/Linux,
$env:USERPROFILE\ChannelAssist on Windows, matching the wizard's
default workspace.

.PARAMETER Force
Overwrite existing foreign commit-msg hooks even if they don't invoke
commitlint. Default behavior preserves them.

.EXAMPLE
./scripts/install-commit-hooks.ps1

.EXAMPLE
./scripts/install-commit-hooks.ps1 -WorkspacePath ~/my-workspace -WhatIf

.EXAMPLE
./scripts/install-commit-hooks.ps1 -Force

.NOTES
Requires Node.js + npx on PATH. The wizard's step 20 (prereqs) ensures
Node is installed; this script only sets up the hooks and assumes Node
is already present. If npx isn't on PATH the installed hook itself
no-ops gracefully (the hook body skips with a warning and exits 0).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkspacePath = $null,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Dot-source the helper functions (Test-CAB*, Get-CAB*). Same pattern
# as the wizard steps, so the helpers can be unit-tested independently
# (see tests/lib/commit-hooks.tests.ps1).
$repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
. (Join-Path $repoRoot 'lib/commit-hooks.ps1')

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

$hookBody = Get-CABCommitMsgHookBody

$stats = [ordered]@{
    Scanned   = 0
    NoConfig  = 0
    Installed = 0
    Updated   = 0
    Skipped   = 0
    Preserved = 0
}

Write-Host "Scanning $WorkspacePath for ChannelAssist clones with commitlint configured..." -ForegroundColor Cyan
Write-Host ""

foreach ($repoDir in (Get-CABCommitlintRepos -WorkspacePath $WorkspacePath)) {
    $stats.Scanned++

    if (-not (Test-CABHasCommitlintConfig -RepoDir $repoDir)) {
        $stats.NoConfig++
        continue
    }

    $hooksDir = Join-Path $repoDir '.git/hooks'
    $hookPath = Join-Path $hooksDir 'commit-msg'
    $rel = Get-CABRelativePath -Path $repoDir -BasePath $WorkspacePath

    # Decide what we WOULD do; stats reflect the plan (so -WhatIf
    # reports counts the same as a real run would).
    $action = $null
    if (Test-CABHookIsOurs -HookPath $hookPath) {
        # Our hook already installed; refresh body in case it changed.
        $existing = Get-Content $hookPath -Raw -ErrorAction SilentlyContinue
        $action = if ($existing -ne $hookBody) { 'Updated' } else { 'Skipped' }
    } elseif (Test-CABHookInvokesCommitlint -HookPath $hookPath) {
        # Foreign hook but already runs commitlint somehow — preserve.
        Write-Host "  [preserve] $rel — existing commit-msg hook already runs commitlint" -ForegroundColor DarkGreen
        $stats.Preserved++
        continue
    } elseif (Test-Path $hookPath) {
        # Foreign hook with no commitlint involvement.
        if ($Force) {
            $action = 'Updated'
        } else {
            Write-Host "  [preserve] $rel — existing commit-msg hook not ours; use -Force to overwrite" -ForegroundColor Yellow
            $stats.Preserved++
            continue
        }
    } else {
        $action = 'Installed'
    }

    # Plan tally first, regardless of whether we end up writing — so
    # -WhatIf produces accurate counts.
    $stats."$action"++

    if ($PSCmdlet.ShouldProcess($hookPath, $action.ToLower())) {
        New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
        Set-Content -Path $hookPath -Value $hookBody
        if (-not $IsWindows) { chmod +x $hookPath }
        Write-Host "  [$($action.ToLower())] $rel" -ForegroundColor Green
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
