#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
ca-bootstrap release cut (Windows-native peer of scripts/release.sh).

.DESCRIPTION
Workflow (matches the org's dev-as-default pattern):

  1. Maintainer opens a PR to dev that bumps $Script:CABootstrapVersion
     in ca-bootstrap.ps1 (and any release notes / CHANGELOG entries).
  2. PR merges into dev (via standard review + CI gate).
  3. Maintainer runs `./make.ps1 release -Version X.Y.Z`.
  4. This script then:
       a. Verifies the version constant on origin/dev already equals VERSION.
       b. Smoke + Pester (skippable for hotfixes).
       c. Fast-forwards origin/main to origin/dev. main-protection blocks
          non-PR pushes, so this disables the ruleset, ff-pushes, and
          re-enables it (verified content-identical via Compare-Object).
          A try/finally guarantees the ruleset is restored even if a later
          step fails.
       d. Creates a GPG-signed tag vX.Y.Z on the new main HEAD.
       e. Pushes the tag.
       f. Creates the GitHub release with -NotesFile or auto-generated
          notes from `git log v<previous>..HEAD`.

Refuses to release if:
  - Version isn't semver
  - Working tree is dirty
  - The tag already exists locally or on origin
  - ca-bootstrap.ps1's version constant on dev doesn't match VERSION
  - Smoke or tests fail (override with -SkipSmoke / -SkipTests)
  - main can't fast-forward to dev (main has commits dev doesn't)
  - Required tools missing (gh)
  - The main-protection ruleset can't be located by name
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
# Trap state — initialized before any failable step that disables the
# ruleset, so the finally block can read them safely on early exits.
# ---------------------------------------------------------------------------

$script:RulesetDisabled    = $false
$script:BeforeEnforcement  = $null
$script:MainRulesetId      = $null
$script:RepoSlug           = $null

# Per-run tempdir. Mirrors `mktemp -d -t cab-release.XXXXXX`. Kept under
# the user's TEMP so a crashed run leaves recoverable forensic data on a
# predictable path.
$script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("cab-release." + ([guid]::NewGuid().ToString('N').Substring(0, 12)))
New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null

# ---------------------------------------------------------------------------
# Ruleset helpers
# ---------------------------------------------------------------------------
#
# GitHub rulesets accept enforcement = active | disabled | evaluate.
# We restore to whatever the user had configured, NOT a hardcoded
# 'active' — forcing active when the user was in evaluate mode would
# silently change policy.

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
    # GitHub's ruleset GET returns more fields than PUT accepts. Project
    # down to the supported shape and override enforcement.
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
    $payloadFile = Join-Path $script:TmpDir 'main-protection-restore.json'
    Set-Content -Path $payloadFile -Value $payload -NoNewline
    & gh api -X PUT "repos/$Repo/rulesets/$RulesetId" --input $payloadFile --jq '.enforcement' | Out-Null
    return $LASTEXITCODE
}

# ---------------------------------------------------------------------------
# 0. Validation
# ---------------------------------------------------------------------------

try {

if ([string]::IsNullOrWhiteSpace($Version)) {
    Stop-WithError "Version is required, e.g. ./make.ps1 release -Version 1.5.0"
}

$Version = $Version -replace '^v', ''
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$') {
    Stop-WithError "Version '$Version' is not semver (expected X.Y.Z or X.Y.Z-suffix)"
}
$tag = "v$Version"

# Working-tree clean check. PowerShell-native equivalent of:
#   git diff --quiet HEAD || git diff --cached --quiet
& git diff --quiet HEAD 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-WithError 'Working tree is dirty. Commit or stash first.'
}
& git diff --cached --quiet 2>$null
if ($LASTEXITCODE -ne 0) {
    Stop-WithError 'Working tree is dirty (staged changes). Commit or stash first.'
}

# Tag must not already exist locally or on origin.
& git rev-parse $tag 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Stop-WithError "Tag $tag already exists locally."
}
$remoteTag = & git ls-remote --tags origin $tag 2>$null
if (-not [string]::IsNullOrWhiteSpace($remoteTag)) {
    Stop-WithError "Tag $tag already exists on origin."
}

# Hard dependency: gh CLI. We don't require jq or diff — we replaced both
# with ConvertFrom-Json + Compare-Object below — so the dependency surface
# on Windows is narrower than the bash version.
if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
    Stop-WithError 'gh not on PATH (required for the ruleset disable-restore play).'
}

# Resolve the GitHub repo from `origin` so a fork running this script
# operates against its own remote, not the upstream — critical for the
# ruleset API calls below.
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
    Stop-WithError 'Could not derive repo slug from `git remote get-url origin` or `gh repo view`.'
}
Write-Ok2 "Version=$Version Tag=$tag Repo=$($script:RepoSlug) (semver, clean tree, tag is new)"

# ---------------------------------------------------------------------------
# 0.5. Interactive manifest review (skippable for CI / hands-off releases)
# ---------------------------------------------------------------------------

if ($SkipManifestEdit) {
    Write-Note 'SkipManifestEdit set, skipping interactive manifest review'
}
elseif ($DryRun) {
    Write-Info 'DryRun: manifest-edit would run here (skipping the actual interactive review)'
}
else {
    Write-Info 'reviewing manifest against the live org...'
    & pwsh -NoLogo -File (Join-Path $script:RepoRoot 'ca-bootstrap.ps1') manifest-edit
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError 'manifest-edit failed — see output above.'
    }
    & git diff --quiet HEAD -- manifest/repos.yaml 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Note ''
        Write-Note 'manifest/repos.yaml was modified by manifest-edit.'
        Write-Note "Commit + push to dev via a PR, merge it, then re-run ./make.ps1 release -Version $Version."
        Write-Note ''
        Write-Note 'This gate ensures the release commit on main reflects the curated manifest.'
        Stop-WithError 'aborting: manifest changes need a PR cycle before tagging.'
    }
    Write-Ok2 'manifest review complete (no changes, safe to continue)'
}

# ---------------------------------------------------------------------------
# 1. Fetch + verify version constant on dev matches VERSION
# ---------------------------------------------------------------------------

Write-Info 'fetching origin...'
& git fetch --quiet --all --tags
if ($LASTEXITCODE -ne 0) { Stop-WithError 'git fetch failed' }

$orchestratorPath = 'ca-bootstrap.ps1'
$devContent = & git show "origin/dev:$orchestratorPath" 2>$null
if ($LASTEXITCODE -ne 0) { Stop-WithError "could not read origin/dev:$orchestratorPath" }

# `head -1` equivalent: -match returns the first capture into $Matches.
if ($devContent -match "Script:CABootstrapVersion = '([^']+)'") {
    $devVersion = $Matches[1]
}
else {
    $devVersion = $null
}
if ([string]::IsNullOrWhiteSpace($devVersion)) {
    Stop-WithError "Could not parse `$Script:CABootstrapVersion from origin/dev:$orchestratorPath"
}

if ($devVersion -ne $Version) {
    Stop-WithError @"
origin/dev has `$Script:CABootstrapVersion = '$devVersion'; release.ps1 refuses to tag $tag.
Open a PR to dev that bumps the constant to '$Version' first, merge it, then re-run.
"@
}
Write-Ok2 "origin/dev already at $Version"

$aheadMain = [int]((& git rev-list --count "origin/dev..origin/main" 2>$null) ?? '0')
$aheadDev  = [int]((& git rev-list --count "origin/main..origin/dev" 2>$null) ?? '0')
if ($aheadMain -gt 0) {
    Stop-WithError "origin/main has $aheadMain commit(s) NOT on origin/dev. main must be a strict ancestor of dev for ff-promotion. Reconcile first."
}
if ($aheadDev -eq 0) {
    Write-Note 'origin/main is already at origin/dev; no promotion needed (will tag the existing HEAD).'
}
Write-Ok2 "main can fast-forward to dev (+$aheadDev commit(s) ahead)"

# ---------------------------------------------------------------------------
# 2. Smoke + tests
# ---------------------------------------------------------------------------

if ($SkipSmoke) {
    Write-Note 'SkipSmoke set, skipping smoke test'
}
elseif ($DryRun) {
    Write-Info 'DryRun: smoke test would run here (skipping the actual smoke target)'
}
else {
    Write-Info 'running ./make.ps1 smoke...'
    & pwsh -NoLogo -File (Join-Path $script:RepoRoot 'make.ps1') smoke *> $null
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'smoke test failed. Pass -SkipSmoke to override.' }
    Write-Ok2 'smoke test passed'
}

if ($SkipTests) {
    Write-Note 'SkipTests set, skipping Pester'
}
elseif ($DryRun) {
    Write-Info 'DryRun: Pester would run here (skipping the actual Invoke-Pester)'
}
else {
    Write-Info 'running Pester...'
    & pwsh -NoLogo -Command @'
$cfg = New-PesterConfiguration
$cfg.Run.Path = './tests'
$cfg.Output.Verbosity = 'Minimal'
$cfg.Run.Exit = $true
Invoke-Pester -Configuration $cfg
'@ *> $null
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Pester tests failed. Pass -SkipTests to override.' }
    Write-Ok2 'Pester tests passed'
}

# ---------------------------------------------------------------------------
# 3. Locate main-protection ruleset by name (fork-safe)
# ---------------------------------------------------------------------------

Write-Info 'locating main-protection ruleset...'
$rulesetIdRaw = & gh api "repos/$($script:RepoSlug)/rulesets" --jq '.[] | select(.name == "main-protection") | .id' 2>$null
$script:MainRulesetId = ($rulesetIdRaw -split "`n" | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($script:MainRulesetId)) {
    Stop-WithError "Could not find a ruleset named 'main-protection' on $($script:RepoSlug). Either it doesn't exist (no protection to disable — push directly?) or the API call failed."
}
Write-Ok2 "main-protection ruleset id = $($script:MainRulesetId)"

# ---------------------------------------------------------------------------
# 4. Confirmation gate
# ---------------------------------------------------------------------------

if (-not $DryRun -and -not $Confirm) {
    Write-Host ''
    Write-Note "About to ff-promote origin/dev -> origin/main and tag $tag on $($script:RepoSlug)."
    $resp = Read-Host "Type 'yes' to proceed, anything else to abort"
    if ($resp -ne 'yes') { Stop-WithError 'aborted by user.' }
}

# ---------------------------------------------------------------------------
# 5. Promote origin/dev -> origin/main (with disable-restore on ruleset)
# ---------------------------------------------------------------------------

if ($aheadDev -gt 0) {
    if (-not $DryRun) {
        Write-Info 'capturing main-protection ruleset...'
        $beforeJson = Get-RulesetJson -RulesetId $script:MainRulesetId -Repo $script:RepoSlug
        if (-not $beforeJson) {
            Stop-WithError "could not read ruleset $($script:MainRulesetId) on $($script:RepoSlug)"
        }
        $beforeFile = Join-Path $script:TmpDir 'main-protection-before.json'
        Set-Content -Path $beforeFile -Value $beforeJson -NoNewline

        $beforeObj = $beforeJson | ConvertFrom-Json
        $script:BeforeEnforcement = $beforeObj.enforcement
        Write-Ok2 "captured (enforcement=$($script:BeforeEnforcement))"

        Write-Info 'disabling main-protection enforcement...'
        $disablePayload = ConvertTo-RulesetPayload -RawJson $beforeJson -Enforcement 'disabled'
        $disableFile = Join-Path $script:TmpDir 'main-protection-disable.json'
        Set-Content -Path $disableFile -Value $disablePayload -NoNewline
        & gh api -X PUT "repos/$($script:RepoSlug)/rulesets/$($script:MainRulesetId)" --input $disableFile --jq '.enforcement' | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'could not disable main-protection ruleset' }
        # Critical: from now until the matching restore, any error path
        # must trigger the finally block to put the ruleset back.
        $script:RulesetDisabled = $true
        Write-Ok2 'main-protection disabled'

        Write-Info 'ff-promoting origin/dev -> origin/main...'
        $origBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
        & git checkout main 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            & git checkout -B main origin/main 2>$null | Out-Null
        }
        & git merge --ff-only origin/dev | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'ff-merge of origin/dev into main failed' }
        & git push origin main | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-WithError 'push to origin/main failed' }
        & git checkout $origBranch 2>$null | Out-Null
        $shortSha = (& git rev-parse --short origin/dev).Trim()
        Write-Ok2 "origin/main fast-forwarded to $shortSha"

        Write-Info 'restoring main-protection enforcement...'
        $restoreRc = Restore-Ruleset -RulesetId $script:MainRulesetId -Repo $script:RepoSlug -BeforeJson $beforeJson -Enforcement $script:BeforeEnforcement
        if ($restoreRc -ne 0) { Stop-WithError 'failed to restore main-protection enforcement' }
        $script:RulesetDisabled = $false

        # Verify content-identical restore (sans updated_at).
        $afterJson = Get-RulesetJson -RulesetId $script:MainRulesetId -Repo $script:RepoSlug
        if ($afterJson) {
            $beforeNorm = $beforeJson | ConvertFrom-Json | Select-Object * -ExcludeProperty updated_at | ConvertTo-Json -Depth 100 -Compress
            $afterNorm  = $afterJson  | ConvertFrom-Json | Select-Object * -ExcludeProperty updated_at | ConvertTo-Json -Depth 100 -Compress
            if ($beforeNorm -ne $afterNorm) {
                Write-Note 'main-protection ruleset content drifted after restore; review manually.'
            }
            else {
                Write-Ok2 'main-protection re-enabled (content-identical)'
            }
        }
    }
    else {
        Write-Info 'DryRun: would ff-promote origin/dev -> origin/main with disable-restore on main-protection'
    }
}

# ---------------------------------------------------------------------------
# 6. Tag main + push tag
# ---------------------------------------------------------------------------

if (-not $DryRun) {
    & git fetch --quiet origin main
    & git tag -s $tag origin/main -m "Release $tag" | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError "git tag -s $tag failed (check GPG signing config)" }
    & git push origin $tag | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError "git push origin $tag failed" }
    Write-Ok2 "GPG-signed tag $tag pushed"
}
else {
    Write-Info "DryRun: would tag origin/main as $tag (signed) and push"
}

# ---------------------------------------------------------------------------
# 7. GitHub release
# ---------------------------------------------------------------------------
#
# Pick the previous tag for changelog generation. `--merged origin/main`
# excludes orphan tags from work that was later squashed and dropped via PR;
# without this, --sort=-v:refname can pick a higher-numbered orphan and emit
# a misleading "Changes since vX.Y.Z" header. Filter out our own tag too —
# we just pushed it in step 6 above.

$allTags = & git tag --merged origin/main --sort=-v:refname 2>$null
$prevTag = ($allTags -split "`n" |
            Where-Object { $_ -match '^v[0-9]+\.[0-9]+\.[0-9]+' } |
            Where-Object { $_ -ne $tag } |
            Select-Object -First 1)
if (-not $prevTag) { $prevTag = '' }

if ($NotesFile -and (Test-Path $NotesFile)) {
    $notesBody = Get-Content -Raw -Path $NotesFile
    Write-Info "release notes from $NotesFile"
}
else {
    Write-Info "auto-generating release notes from $prevTag..$tag"
    if ($prevTag) {
        $rawCommits = & git log --pretty=format:'- %s' "$prevTag..origin/main" 2>$null
    }
    else {
        $rawCommits = & git log --pretty=format:'- %s' "origin/main" 2>$null
    }
    $commitLines = ($rawCommits -split "`n") | Where-Object { $_ -notmatch '^- release:' }
    if (-not $prevTag) { $commitLines = $commitLines | Select-Object -First 50 }
    $commits = $commitLines -join "`n"

    $notesBody = @"
ca-bootstrap $tag

## Changes since $prevTag

$commits

## Bootstrap one-liners (pinned to $tag)

``````powershell
# Windows
iwr -useb https://raw.githubusercontent.com/$($script:RepoSlug)/$tag/bootstrap.ps1 | iex
``````

``````bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/$($script:RepoSlug)/$tag/bootstrap.sh | bash
``````
"@
}

if (-not $DryRun) {
    $notesFileTmp = Join-Path $script:TmpDir 'release-notes.md'
    Set-Content -Path $notesFileTmp -Value $notesBody -NoNewline
    & gh release create $tag --title "ca-bootstrap $tag" --notes-file $notesFileTmp --target main | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WithError "gh release create $tag failed" }
    $url = & gh release view $tag --json url -q .url
    Write-Ok2 "GitHub release created: $url"
}
else {
    Write-Info 'DryRun: would create GitHub release with notes:'
    Write-Host $notesBody
}

Write-Ok2 "Release $tag complete."

}
finally {
    # Best-effort restore mirroring the bash EXIT trap. If we disabled the
    # ruleset and didn't reach the matching restore (e.g. an early exit on
    # a failed git push), put enforcement back. Without this, a mid-flight
    # error leaves main-protection wide open for the next push.
    $preserveTmpDir = $false
    if ($script:RulesetDisabled -and
        $script:MainRulesetId -and
        $script:RepoSlug -and
        $script:BeforeEnforcement) {
        Write-Note "main-protection still disabled at exit — restoring to '$($script:BeforeEnforcement)'..."
        $beforeFile = Join-Path $script:TmpDir 'main-protection-before.json'
        if (Test-Path $beforeFile) {
            $beforeJson = Get-Content -Raw -Path $beforeFile
            $rc = Restore-Ruleset -RulesetId $script:MainRulesetId -Repo $script:RepoSlug -BeforeJson $beforeJson -Enforcement $script:BeforeEnforcement
            if ($rc -eq 0) {
                Write-Note 'main-protection re-enabled (best-effort post-failure)'
            }
            else {
                Write-Bad "*** CRITICAL: main-protection ruleset $($script:MainRulesetId) may still be DISABLED. Re-enable manually:"
                Write-Bad "    gh api -X PUT repos/$($script:RepoSlug)/rulesets/$($script:MainRulesetId) --input '$beforeFile'"
                # Preserve the tempdir on critical failure so the operator
                # can use the printed gh command. (PowerShell forbids
                # `return` inside a finally block — flag the skip instead.)
                $preserveTmpDir = $true
            }
        }
    }
    if (-not $preserveTmpDir -and (Test-Path $script:TmpDir)) {
        Remove-Item -Recurse -Force $script:TmpDir
    }
}
