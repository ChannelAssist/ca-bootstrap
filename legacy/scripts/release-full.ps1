#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
ca-bootstrap bump-and-release in one command (Windows-native peer of
scripts/release-full.sh).

.DESCRIPTION
Wraps scripts/release.ps1 by adding the version-bump PR cycle:

  1. Branch chore/v$VERSION-release off origin/dev
  2. Bump $Script:CABootstrapVersion in ca-bootstrap.ps1
  3. Commit + push, open PR to dev
  4. Admin-merge the bump PR via dev-protection disable-restore
     (a try/finally restores enforcement even if the merge fails)
  5. Hand off to scripts/release.ps1 which does manifest-edit, smoke,
     Pester, ff-promote dev->main, GPG-signed tag, GH release

Trade-off vs. the manual release flow: this skips review on the bump PR.
Use for hotfix releases or single-maintainer projects. For multi-maintainer
projects where bumps need review (CHANGELOG entry, breaking-change tags),
use the 3-step manual flow:
  1. Open PR to dev that bumps $Script:CABootstrapVersion
  2. Merge it after review
  3. Run ./make.ps1 release -Version X.Y.Z

If origin/dev is already at $VERSION, this script skips the bump PR step
and proceeds directly to release.ps1 — so re-running after a manual bump
is safe.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$NotesFile,
    [switch]$SkipSmoke,
    [switch]$SkipTests,
    [switch]$SkipManifestEdit,
    [switch]$DryRun,
    [switch]$Confirm
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $script:RepoRoot

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

function Write-Bad  { param([string]$Msg) Write-Host "ERROR: $Msg" -ForegroundColor Red }
function Write-Ok2  { param([string]$Msg) Write-Host "OK $Msg"     -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "-> $Msg"     -ForegroundColor Blue }
function Write-Note { param([string]$Msg) Write-Host "WARN: $Msg"  -ForegroundColor Yellow }

function Stop-WithError {
    param([string]$Msg, [int]$Code = 1)
    Write-Bad $Msg
    exit $Code
}

# ---------------------------------------------------------------------------
# Trap state
# ---------------------------------------------------------------------------

$script:RulesetDisabled    = $false
$script:BeforeEnforcement  = $null
$script:DevRulesetId       = $null
$script:RepoSlug           = $null
$script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("cab-relfull." + ([guid]::NewGuid().ToString('N').Substring(0, 12)))
New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null

# ---------------------------------------------------------------------------
# Ruleset helpers (mirror release.ps1 — kept inline rather than dot-sourced
# so this script remains runnable standalone for dry-runs / forensics).
# ---------------------------------------------------------------------------

function Get-RulesetJson {
    param([string]$RulesetId, [string]$Repo)
    $raw = & gh api "repos/$Repo/rulesets/$RulesetId" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return $raw
}

function ConvertTo-RulesetPayload {
    param(
        [Parameter(Mandatory)][string]$RawJson,
        [Parameter(Mandatory)][string]$Enforcement
    )
    $obj = $RawJson | ConvertFrom-Json
    $payload = [ordered]@{
        name        = $obj.name
        target      = $obj.target
        source_type = $obj.source_type
        source      = $obj.source
        enforcement = $Enforcement
        conditions  = $obj.conditions
        rules       = $obj.rules
    }
    return ($payload | ConvertTo-Json -Depth 100 -Compress)
}

function Restore-Ruleset {
    param(
        [Parameter(Mandatory)][string]$RulesetId,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$BeforeJson,
        [Parameter(Mandatory)][string]$Enforcement
    )
    $payload = ConvertTo-RulesetPayload -RawJson $BeforeJson -Enforcement $Enforcement
    $payloadFile = Join-Path $script:TmpDir 'dev-protection-restore.json'
    Set-Content -Path $payloadFile -Value $payload -NoNewline
    & gh api -X PUT "repos/$Repo/rulesets/$RulesetId" --input $payloadFile --jq '.enforcement' | Out-Null
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# 0. Validation
# ---------------------------------------------------------------------------

try {

if ([string]::IsNullOrWhiteSpace($Version)) {
    Stop-WithError "Version is required, e.g. ./make.ps1 release-full -Version 1.5.0"
}

$Version = $Version -replace '^v', ''
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$') {
    Stop-WithError "Version '$Version' is not semver (expected X.Y.Z or X.Y.Z-suffix)"
}
$tag = "v$Version"

& git diff --quiet HEAD 2>$null
if ($LASTEXITCODE -ne 0) { Stop-WithError 'Working tree is dirty. Commit or stash first.' }
& git diff --cached --quiet 2>$null
if ($LASTEXITCODE -ne 0) { Stop-WithError 'Working tree is dirty (staged changes). Commit or stash first.' }

& git rev-parse $tag 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Stop-WithError "Tag $tag already exists locally." }
$remoteTag = & git ls-remote --tags origin $tag 2>$null
if (-not [string]::IsNullOrWhiteSpace($remoteTag)) { Stop-WithError "Tag $tag already exists on origin." }

if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
    Stop-WithError 'gh not on PATH (required for the bump-and-merge play).'
}

$originUrl = (& git remote get-url origin 2>$null)
if ($LASTEXITCODE -ne 0) { $originUrl = '' }
$script:RepoSlug = $originUrl -replace '^https?://[^/]+/', '' `
                              -replace '^git@[^:]+:', '' `
                              -replace '\.git$', '' `
                              -replace '\s', ''
if ([string]::IsNullOrWhiteSpace($script:RepoSlug) -or $script:RepoSlug -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
    $script:RepoSlug = & gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
}
if ([string]::IsNullOrWhiteSpace($script:RepoSlug)) {
    Stop-WithError 'Could not derive repo slug from origin remote.'
}
Write-Ok2 "Version=$Version Tag=$tag Repo=$($script:RepoSlug)"

# ---------------------------------------------------------------------------
# 1. Inspect origin/dev's current version
# ---------------------------------------------------------------------------

Write-Info 'fetching origin...'
& git fetch --quiet --all --tags
if ($LASTEXITCODE -ne 0) { Stop-WithError 'git fetch failed' }

$devContent = & git show "origin/dev:ca-bootstrap.ps1" 2>$null
if ($LASTEXITCODE -ne 0) { Stop-WithError 'could not read origin/dev:ca-bootstrap.ps1' }
if ($devContent -match "Script:CABootstrapVersion = '([^']+)'") {
    $devVersion = $Matches[1]
}
else {
    $devVersion = $null
}
if ([string]::IsNullOrWhiteSpace($devVersion)) {
    Stop-WithError 'Could not parse $Script:CABootstrapVersion from origin/dev:ca-bootstrap.ps1'
}

$skipBumpPr = $false
if ($devVersion -eq $Version) {
    Write-Info "origin/dev is already at $Version — skipping bump PR; proceeding directly to release.ps1"
    $skipBumpPr = $true
}
else {
    Write-Info "origin/dev currently at $devVersion; will bump to $Version via auto-merged PR"
}

# ---------------------------------------------------------------------------
# 2. Confirmation gate
# ---------------------------------------------------------------------------

if (-not $DryRun -and -not $Confirm) {
    Write-Host ''
    Write-Note "About to: bump dev to $Version (auto-merged PR), then run release.ps1 to ff-promote main, tag $tag, create release."
    $resp = Read-Host "Type 'yes' to proceed, anything else to abort"
    if ($resp -ne 'yes') { Stop-WithError 'aborted by user.' }
}

# ---------------------------------------------------------------------------
# 3. Bump-PR cycle (skipped if dev is already at target)
# ---------------------------------------------------------------------------

if (-not $skipBumpPr) {
    $bumpBranch = "chore/v$Version-release"

    if (-not $DryRun) {
        # Refuse if the branch already exists on origin — defends against a
        # previous run that crashed mid-flight; the maintainer should clean
        # up before retrying.
        $remoteBranch = & git ls-remote --heads origin $bumpBranch 2>$null
        if (-not [string]::IsNullOrWhiteSpace($remoteBranch)) {
            Stop-WithError "Branch $bumpBranch already exists on origin. Investigate (`gh pr list --head $bumpBranch`); delete manually if stale, then re-run."
        }

        $origBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
        Write-Info "creating bump branch $bumpBranch off origin/dev..."
        & git checkout -B $bumpBranch origin/dev 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError "could not create bump branch $bumpBranch" }

        Write-Info "bumping ca-bootstrap.ps1 -> $Version..."
        $orchestratorFile = Join-Path $script:RepoRoot 'ca-bootstrap.ps1'
        $content = Get-Content -Raw -Path $orchestratorFile
        $newContent = $content -replace "(Script:CABootstrapVersion = ')[^']+(')", "`${1}$Version`${2}"
        if ($content -eq $newContent) {
            Stop-WithError "Bump produced no diff — `$Script:CABootstrapVersion may have been at $Version already on dev (the earlier check should have caught this)."
        }
        # ca-bootstrap.ps1 ships with a UTF-8 BOM and the file's existing line
        # endings — Set-Content default ('Default' on Windows = system encoding,
        # 'utf8NoBOM' on others) would strip the BOM and normalize EOLs,
        # producing a noisy unrelated diff. Pin both to preserve byte-for-byte.
        Set-Content -Path $orchestratorFile -Value $newContent -NoNewline -Encoding utf8BOM

        & git diff --quiet HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            Stop-WithError "Bump produced no diff against HEAD — version constant may have been at $Version on dev already."
        }

        & git add ca-bootstrap.ps1
        # No Co-Authored-By footer here — this commit fires from any
        # maintainer's machine running release-full, not from a Claude
        # session.
        $commitMsg = @"
release: bump version to $tag

Auto-generated by ./make.ps1 release-full -Version $Version.
"@
        & git commit -m $commitMsg | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'git commit failed' }
        Write-Ok2 'committed bump'

        Write-Info "pushing $bumpBranch..."
        & git push -u origin $bumpBranch 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError "git push -u origin $bumpBranch failed" }
        Write-Ok2 'pushed'

        Write-Info 'opening bump PR...'
        $prBody = "Auto-generated by ``./make.ps1 release-full -Version $Version``. Bumps `$Script:CABootstrapVersion to $Version on the road to tagging $tag. Auto-merged immediately by the script via dev-protection disable-restore play; no human review on the bump itself."
        $prCreateOutput = & gh pr create --base dev --head $bumpBranch `
            --title "release: bump version to $tag" `
            --body $prBody `
            --label chore 2>&1
        if ($LASTEXITCODE -ne 0) { Stop-WithError "gh pr create failed: $prCreateOutput" }
        # gh pr create's last line is the PR URL; pull the trailing digit run.
        $prUrl = ($prCreateOutput -split "`n" | Select-Object -Last 1).Trim()
        if ($prUrl -match '/(\d+)$') {
            $prNum = $Matches[1]
        }
        else {
            Stop-WithError "Could not extract PR number from URL: $prUrl"
        }
        Write-Ok2 "PR #$prNum created"

        # Locate dev-protection ruleset by name (fork-safe).
        Write-Info 'locating dev-protection ruleset...'
        $rulesetIdRaw = & gh api "repos/$($script:RepoSlug)/rulesets" --jq '.[] | select(.name == "dev-protection") | .id' 2>$null
        $script:DevRulesetId = ($rulesetIdRaw -split "`n" | Select-Object -First 1).Trim()
        if ([string]::IsNullOrWhiteSpace($script:DevRulesetId)) {
            Stop-WithError "Could not find dev-protection ruleset on $($script:RepoSlug)."
        }
        Write-Ok2 "dev-protection ruleset id = $($script:DevRulesetId)"

        Write-Info 'capturing dev-protection state...'
        $beforeJson = Get-RulesetJson -RulesetId $script:DevRulesetId -Repo $script:RepoSlug
        if (-not $beforeJson) {
            Stop-WithError "could not read ruleset $($script:DevRulesetId)"
        }
        $beforeFile = Join-Path $script:TmpDir 'dev-protection-before.json'
        Set-Content -Path $beforeFile -Value $beforeJson -NoNewline
        $beforeObj = $beforeJson | ConvertFrom-Json
        $script:BeforeEnforcement = $beforeObj.enforcement
        Write-Ok2 "captured (enforcement=$($script:BeforeEnforcement))"

        Write-Info 'disabling dev-protection enforcement...'
        $disablePayload = ConvertTo-RulesetPayload -RawJson $beforeJson -Enforcement 'disabled'
        $disableFile = Join-Path $script:TmpDir 'dev-protection-disable.json'
        Set-Content -Path $disableFile -Value $disablePayload -NoNewline
        & gh api -X PUT "repos/$($script:RepoSlug)/rulesets/$($script:DevRulesetId)" --input $disableFile --jq '.enforcement' | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'could not disable dev-protection ruleset' }
        $script:RulesetDisabled = $true
        Write-Ok2 'dev-protection disabled'

        Write-Info "squash-merging bump PR #$prNum..."
        & gh pr merge $prNum --squash `
            --subject "release: bump version to $tag (#$prNum)" `
            --body "Auto-merged by ./make.ps1 release-full -Version $Version." | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError "gh pr merge $prNum failed" }
        Write-Ok2 'merged'

        Write-Info 'restoring dev-protection enforcement...'
        $restoreRc = Restore-Ruleset -RulesetId $script:DevRulesetId -Repo $script:RepoSlug -BeforeJson $beforeJson -Enforcement $script:BeforeEnforcement
        if ($restoreRc -ne 0) { Stop-WithError 'failed to restore dev-protection enforcement' }
        $script:RulesetDisabled = $false

        $afterJson = Get-RulesetJson -RulesetId $script:DevRulesetId -Repo $script:RepoSlug
        if ($afterJson) {
            $beforeNorm = $beforeJson | ConvertFrom-Json | Select-Object * -ExcludeProperty updated_at | ConvertTo-Json -Depth 100 -Compress
            $afterNorm  = $afterJson  | ConvertFrom-Json | Select-Object * -ExcludeProperty updated_at | ConvertTo-Json -Depth 100 -Compress
            if ($beforeNorm -ne $afterNorm) {
                Write-Note 'dev-protection ruleset content drifted after restore; review manually.'
            }
            else {
                Write-Ok2 'dev-protection re-enabled (content-identical)'
            }
        }

        # Restore the user's original branch + clean up the local bump branch.
        & git checkout $origBranch 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { & git checkout main 2>$null | Out-Null }
        & git branch -D $bumpBranch 2>$null | Out-Null

        Write-Info 'fetching to sync with new dev HEAD...'
        & git fetch --quiet origin
    }
    else {
        Write-Info "DryRun: would create $bumpBranch off origin/dev, bump version, push, open PR, admin-merge"
    }
}

# ---------------------------------------------------------------------------
# 4. Hand off to release.ps1
# ---------------------------------------------------------------------------

Write-Host ''
Write-Info '======================================================================'
Write-Info '  Bump complete. Continuing to scripts/release.ps1:'
Write-Info '    manifest-edit -> smoke + Pester -> ff-promote dev->main -> tag -> GH release'
Write-Info '======================================================================'
Write-Host ''

# DryRun handling has two cases:
#
#   * Bump-PR was skipped (skipBumpPr=true, dev's version already at target):
#     release.ps1's precondition (origin/dev's version == VERSION) is
#     genuinely satisfied, so we CAN cascade DryRun through. This validates
#     the full chain end-to-end.
#
#   * Bump-PR was needed: we didn't actually bump in dry-run, so release.ps1
#     would refuse with a misleading "version mismatch" error. Short-circuit
#     instead and explain.
if ($DryRun -and -not $skipBumpPr) {
    Write-Info "DryRun: scripts/release.ps1 would run next with -Version $Version."
    Write-Info '         Skipping the actual handoff because dev was not bumped'
    Write-Info "         in this dry-run (it'd refuse to tag $tag against the"
    Write-Info '         unchanged version constant). To dry-run the release.ps1'
    Write-Info "         half in isolation, bump dev manually first then run"
    Write-Info "         ./make.ps1 release-dry-run -Version $Version."
    Write-Ok2 'DryRun: release-full plan validated through bump step (no mutations).'
    exit 0
}

# Run release.ps1 as a child process so the finally block in this script
# still fires for tempdir cleanup. -Confirm skips the second confirmation
# gate (we already confirmed up top).
$releaseScript = Join-Path $script:RepoRoot 'scripts' 'release.ps1'
$releaseArgs = @('-Version', $Version, '-Confirm')
if ($NotesFile)        { $releaseArgs += @('-NotesFile', $NotesFile) }
if ($SkipSmoke)        { $releaseArgs += '-SkipSmoke' }
if ($SkipTests)        { $releaseArgs += '-SkipTests' }
if ($SkipManifestEdit) { $releaseArgs += '-SkipManifestEdit' }
if ($DryRun)           { $releaseArgs += '-DryRun' }

& pwsh -NoLogo -File $releaseScript @releaseArgs
exit $LASTEXITCODE

}
finally {
    # Best-effort restore mirroring the bash EXIT trap. Restore using the
    # ORIGINAL enforcement value (not hardcoded 'active') so dev-protection
    # in evaluate mode doesn't silently flip to active.
    $preserveTmpDir = $false
    if ($script:RulesetDisabled -and
        $script:DevRulesetId -and
        $script:RepoSlug -and
        $script:BeforeEnforcement) {
        Write-Note "dev-protection still disabled at exit — restoring to '$($script:BeforeEnforcement)'..."
        $beforeFile = Join-Path $script:TmpDir 'dev-protection-before.json'
        if (Test-Path $beforeFile) {
            $beforeJson = Get-Content -Raw -Path $beforeFile
            $rc = Restore-Ruleset -RulesetId $script:DevRulesetId -Repo $script:RepoSlug -BeforeJson $beforeJson -Enforcement $script:BeforeEnforcement
            if ($rc -eq 0) {
                Write-Note 'dev-protection re-enabled (best-effort post-failure)'
            }
            else {
                Write-Bad "*** CRITICAL: dev-protection ruleset $($script:DevRulesetId) may still be DISABLED. Re-enable manually:"
                Write-Bad "    gh api -X PUT repos/$($script:RepoSlug)/rulesets/$($script:DevRulesetId) --input '$beforeFile'"
                # PowerShell forbids `return` inside a finally block —
                # flag the skip so the tempdir is preserved for forensics.
                $preserveTmpDir = $true
            }
        }
    }
    if (-not $preserveTmpDir -and (Test-Path $script:TmpDir)) {
        Remove-Item -Recurse -Force $script:TmpDir
    }
}
