#!/usr/bin/env pwsh
#requires -Version 7.0
<#
.SYNOPSIS
ca-bootstrap make-equivalent for Windows-native developers.

.DESCRIPTION
Mirror of every Makefile target in pure PowerShell. No bash, no Git Bash,
no WSL — runs on Windows PowerShell 7+ (pwsh) directly. Each target is a
function; typed parameters per target. The Makefile remains the source of
truth for Mac/Linux developers; this script is the Windows-native peer.

.EXAMPLE
./make.ps1 help                                # show all targets
./make.ps1 smoke                               # hermetic smoke test
./make.ps1 tool-install -Tool dotnet-10        # install one tool
./make.ps1 repair -All                         # repair every tool
./make.ps1 release -Version 1.5.0              # cut a release
./make.ps1 nuke -IncludeTools -Confirm         # full purge + tools
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target = 'help',

    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$RemainingArgs
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $PSCommandPath
Set-Location $script:Root

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:Pwsh           = if ($env:PWSH) { $env:PWSH } else { 'pwsh' }
$script:SmokeState     = Join-Path ([IO.Path]::GetTempPath()) 'cab-smoke-state'
$script:SmokeWorkspace = Join-Path ([IO.Path]::GetTempPath()) 'cab-smoke-workspace' 'ChannelAssistDev'

# Single source of truth for target descriptions used by the help target.
# Keep this in lockstep with the function names below.
$script:TargetDescriptions = [ordered]@{
    'help'                   = 'Show this help (default target)'
    'smoke'                  = 'Run an end-to-end smoke test against TEMP (no real workspace touched)'
    'smoke-clean'            = 'Remove smoke-test temp state'
    'setup'                  = 'Run interactive setup wizard. Passes -ConfigFile / -Unattended through to ca-bootstrap.ps1.'
    'doctor'                 = 'Run doctor (exit 2 = drift found, mapped to 0 here)'
    'repair'                 = 'Run repair. Use -All or -Target <id> (e.g. -Target dotnet-10)'
    'undo'                   = 'Run undo. Use -Target <name> or -Force'
    'nuke'                   = 'Full purge. -IncludeTools also uninstalls system tools. -Confirm skips prompt. -DryRun prints the plan.'
    'install-commit-hooks'   = 'Install commitlint hooks across the workspace. -WorkspacePath, -WhatIf, -Force.'
    'tool-list'              = 'List every tool ID in manifest/tools.yaml'
    'tool-install'           = 'Install or upgrade a single tool by ID, e.g. -Tool dotnet-10. Idempotent.'
    'tool-update'            = 'Alias for tool-install (repair is version-aware)'
    'tool-remove'            = 'Uninstall a single tool by ID, e.g. -Tool dotnet-10. Implicitly destructive.'
    'manifest-drift'         = 'Show drift between manifest/repos.yaml and the live org (exit 8 = drift, mapped to 0 here)'
    'manifest-edit'          = 'Interactively curate manifest/repos.yaml'
    'test'                   = 'Run Pester unit tests under tests/'
    'lint'                   = 'Run PSScriptAnalyzer and markdownlint-cli2 (if installed)'
    'format'                 = 'Apply PSScriptAnalyzer auto-fix'
    'wiki-clone'             = 'Clone the GitHub wiki repo into ./wiki'
    'wiki-sync'              = 'Mirror README + DESIGN + docs/ into ./wiki (no push)'
    'wiki-push'              = 'Commit + push wiki changes'
    'wiki-update'            = 'wiki-sync + wiki-push (typical workflow)'
    'clean'                  = 'Remove caches and ephemeral state'
    'release'                = 'Cut a release. -Version X.Y.Z required. See release.ps1 docs for flags.'
    'release-dry-run'        = 'release with -DryRun (no mutations)'
    'release-full'           = 'Bump dev + admin-merge bump PR + release in one shot'
    'release-full-dry-run'   = 'release-full with -DryRun'
    'tag'                    = 'Plain tag-and-push (-Version X.Y.Z) — prefer release'
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Msg) Write-Host $Msg -ForegroundColor Blue }
function Write-Ok   { param([string]$Msg) Write-Host "OK: $Msg" -ForegroundColor Green }
function Write-Note { param([string]$Msg) Write-Host $Msg -ForegroundColor Yellow }
function Write-Bad  { param([string]$Msg) Write-Host $Msg -ForegroundColor Red }

function Invoke-CaBootstrap {
    [CmdletBinding()]
    param([string[]]$Arguments)
    & $script:Pwsh -NoLogo -File (Join-Path $script:Root 'ca-bootstrap.ps1') @Arguments
    return $LASTEXITCODE
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Convert-TargetToFunctionName {
    param([string]$T)
    $pascal = -join (($T -split '-') | ForEach-Object {
        if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() } else { '' }
    })
    return "Invoke-$pascal"
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

function Invoke-Help {
    Write-Step 'ca-bootstrap make targets (Windows-native; mirror of the Makefile)'
    Write-Host ''
    $widest = ($script:TargetDescriptions.Keys | Measure-Object -Property Length -Maximum).Maximum
    foreach ($name in $script:TargetDescriptions.Keys) {
        $padded = $name.PadRight($widest)
        Write-Host ("  ") -NoNewline
        Write-Host $padded -ForegroundColor Yellow -NoNewline
        Write-Host ("  " + $script:TargetDescriptions[$name])
    }
    Write-Host ''
    Write-Host 'Usage:'
    Write-Host '  ./make.ps1 <target> [-FlagsPerTarget ...]'
    Write-Host ''
    Write-Host 'Examples:'
    Write-Host '  ./make.ps1 smoke'
    Write-Host '  ./make.ps1 tool-install -Tool dotnet-10'
    Write-Host '  ./make.ps1 repair -All'
    Write-Host '  ./make.ps1 release -Version 1.5.0'
}

function Invoke-Smoke {
    Write-Step 'Running ca-bootstrap smoke test...'
    if (Test-Path $script:SmokeState)     { Remove-Item -Recurse -Force $script:SmokeState }
    if (Test-Path $script:SmokeWorkspace) { Remove-Item -Recurse -Force $script:SmokeWorkspace }

    $env:CA_BOOTSTRAP_STATE     = $script:SmokeState
    $env:CA_BOOTSTRAP_WORKSPACE = $script:SmokeWorkspace
    try {
        $rc = Invoke-CaBootstrap -Arguments @(
            'setup',
            '-Unattended',
            '-ConfigFile', 'tests/fixtures/answers/hermetic.yaml'
        )
        if ($rc -ne 0) {
            Write-Bad "Smoke test FAILED (exit $rc)"
            exit $rc
        }
        Write-Ok 'Smoke test passed'
    }
    finally {
        Remove-Item Env:CA_BOOTSTRAP_STATE     -ErrorAction SilentlyContinue
        Remove-Item Env:CA_BOOTSTRAP_WORKSPACE -ErrorAction SilentlyContinue
    }
}

function Invoke-Smokeclean {
    if (Test-Path $script:SmokeState)     { Remove-Item -Recurse -Force $script:SmokeState }
    if (Test-Path $script:SmokeWorkspace) { Remove-Item -Recurse -Force $script:SmokeWorkspace }
    Write-Ok 'Smoke state cleaned'
}

function Invoke-Setup {
    [CmdletBinding()]
    param(
        [string]$ConfigFile,
        [switch]$Unattended,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Extra
    )
    $argList = @('setup')
    if ($Unattended) { $argList += '-Unattended' }
    if ($ConfigFile) { $argList += @('-ConfigFile', $ConfigFile) }
    if ($Extra)      { $argList += $Extra }
    $rc = Invoke-CaBootstrap -Arguments $argList
    # ca-bootstrap.ps1 returns 1 when the user voluntarily quits the wizard
    # (documented in docs/commands.md). The Makefile remaps that to 0 so a
    # quit doesn't read as a crash; mirror that here. Real errors (rc >= 2)
    # propagate unchanged.
    if ($rc -eq 1) { exit 0 } else { exit $rc }
}

function Invoke-Doctor {
    [CmdletBinding()]
    param(
        [switch]$Json,
        [switch]$Summary,
        [switch]$Quiet,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Extra
    )
    $argList = @('doctor')
    if ($Json)    { $argList += '-Json' }
    if ($Summary) { $argList += '-Summary' }
    if ($Quiet)   { $argList += '-Quiet' }
    if ($Extra)   { $argList += $Extra }
    $rc = Invoke-CaBootstrap -Arguments $argList
    # Exit 2 from doctor means "drift detected" — it's diagnostic output,
    # not a tooling failure. Map to 0 for the same reason the Makefile does.
    if ($rc -eq 0 -or $rc -eq 2) { exit 0 } else { exit $rc }
}

function Invoke-Repair {
    [CmdletBinding()]
    param(
        [switch]$All,
        [string]$Target,
        [switch]$Force,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Extra
    )
    if (-not $All -and -not $Target -and -not $Extra) {
        Write-Note 'Hint: pass -All or -Target <id>, e.g. ./make.ps1 repair -Target dotnet-10'
    }
    $argList = @('repair')
    if ($All)    { $argList += '-All' }
    if ($Target) { $argList += @('-Target', $Target) }
    if ($Force)  { $argList += '-Force' }
    if ($Extra)  { $argList += $Extra }
    exit (Invoke-CaBootstrap -Arguments $argList)
}

function Invoke-Undo {
    [CmdletBinding()]
    param(
        [switch]$All,
        [string]$Target,
        [switch]$Force,
        [switch]$IncludeFolders,
        [switch]$IncludeTools,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Extra
    )
    $argList = @('undo')
    if ($All)            { $argList += '-All' }
    if ($Target)         { $argList += @('-Target', $Target) }
    if ($Force)          { $argList += '-Force' }
    if ($IncludeFolders) { $argList += '-IncludeFolders' }
    if ($IncludeTools)   { $argList += '-IncludeTools' }
    if ($Extra)          { $argList += $Extra }
    exit (Invoke-CaBootstrap -Arguments $argList)
}

function Invoke-Nuke {
    [CmdletBinding()]
    param(
        [switch]$IncludeTools,
        [switch]$Confirm,
        [switch]$DryRun
    )
    $scriptPath = Join-Path $script:Root 'scripts' 'nuke.ps1'
    if (-not (Test-Path $scriptPath)) {
        Write-Bad "scripts/nuke.ps1 not found at $scriptPath"
        exit 1
    }
    & $script:Pwsh -NoLogo -File $scriptPath `
        -IncludeTools:$IncludeTools `
        -Confirm:$Confirm `
        -DryRun:$DryRun
    exit $LASTEXITCODE
}

function Invoke-Installcommithooks {
    [CmdletBinding()]
    param(
        [string]$WorkspacePath,
        [switch]$WhatIf,
        [switch]$Force
    )
    $scriptPath = Join-Path $script:Root 'scripts' 'install-commit-hooks.ps1'
    $argList = @()
    if ($WorkspacePath) { $argList += @('-WorkspacePath', $WorkspacePath) }
    if ($WhatIf)        { $argList += '-WhatIf' }
    if ($Force)         { $argList += '-Force' }
    & $script:Pwsh -NoLogo -File $scriptPath @argList
    exit $LASTEXITCODE
}

function Invoke-Toollist {
    # Re-uses ca-bootstrap's own libraries so we don't duplicate the
    # manifest-parsing logic. Same approach as the Makefile target — see the
    # corresponding rule in Makefile for the reasoning (Read-CABManifest
    # wraps the yaml init + module import).
    & $script:Pwsh -NoLogo -Command @'
. ./lib/ui.ps1
. ./lib/yaml.ps1
$m = Read-CABManifest -Path manifest/tools.yaml -Quiet
Write-Host 'required:'
@($m.required) | ForEach-Object { Write-Host ("  " + $_.id) }
Write-Host 'optional:'
@($m.optional) | ForEach-Object { Write-Host ("  " + $_.id) }
'@
    exit $LASTEXITCODE
}

function Invoke-Toolinstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tool
    )
    if (-not $Tool) {
        Write-Bad '-Tool is required, e.g. ./make.ps1 tool-install -Tool dotnet-10. Use ./make.ps1 tool-list to see IDs.'
        exit 2
    }
    exit (Invoke-CaBootstrap -Arguments @('repair', '-Target', $Tool))
}

function Invoke-Toolupdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tool
    )
    # repair is version-aware: upgrades if below manifest min, no-op otherwise.
    # Same target as tool-install — kept as a separate verb purely for
    # discoverability in `./make.ps1 help`.
    Invoke-Toolinstall -Tool $Tool
}

function Invoke-Toolremove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tool
    )
    if (-not $Tool) {
        Write-Bad '-Tool is required, e.g. ./make.ps1 tool-remove -Tool dotnet-10.'
        exit 2
    }
    exit (Invoke-CaBootstrap -Arguments @(
        'undo', '-Target', "tool.$Tool", '-IncludeTools', '-Force'
    ))
}

function Invoke-Manifestdrift {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Extra
    )
    $argList = @('manifest-drift')
    if ($Extra) { $argList += $Extra }
    $rc = Invoke-CaBootstrap -Arguments $argList
    # Exit 8 = drift detected (diagnostic, not failure). Mirror the Makefile.
    if ($rc -eq 0 -or $rc -eq 8) { exit 0 } else { exit $rc }
}

function Invoke-Manifestedit {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Extra
    )
    $argList = @('manifest-edit')
    if ($Extra) { $argList += $Extra }
    exit (Invoke-CaBootstrap -Arguments $argList)
}

function Invoke-Test {
    Write-Step 'Running Pester tests...'
    & $script:Pwsh -NoLogo -Command 'Invoke-Pester -Path ./tests -Output Detailed -CI'
    exit $LASTEXITCODE
}

function Invoke-Lint {
    Write-Step 'Linting PowerShell...'
    & $script:Pwsh -NoLogo -Command @'
Invoke-ScriptAnalyzer -Path . -Recurse `
    -Severity Warning `
    -ExcludeRule PSAvoidUsingWriteHost,PSUseShouldProcessForStateChangingFunctions,PSAvoidUsingPositionalParameters |
    Format-Table
'@
    $psRc = $LASTEXITCODE

    if (Test-CommandExists 'markdownlint-cli2') {
        Write-Step 'Linting Markdown...'
        # The Makefile excludes wiki/ and .github/ from the markdown lint pass —
        # the wiki tree is generated and would re-flag rules that don't apply
        # to GitHub Wiki rendering, and .github/ template files have their own
        # lint exemptions in the templates themselves.
        markdownlint-cli2 "**/*.md" "!wiki/**" "!.github/**"
        $mdRc = $LASTEXITCODE
    }
    else {
        Write-Note 'markdownlint-cli2 not installed — skipping Markdown lint'
        $mdRc = 0
    }
    if ($psRc -ne 0) { exit $psRc }
    exit $mdRc
}

function Invoke-Format {
    & $script:Pwsh -NoLogo -Command @'
Get-ChildItem -Recurse -Include *.ps1,*.psm1 | ForEach-Object {
    Invoke-Formatter -ScriptDefinition (Get-Content -Raw $_.FullName) | Set-Content $_.FullName
}
'@
    Write-Ok 'Formatted'
}

function Invoke-Wikiclone {
    $scriptPath = Join-Path $script:Root 'scripts' 'wiki-sync.ps1'
    & $script:Pwsh -NoLogo -File $scriptPath clone
    exit $LASTEXITCODE
}

function Invoke-Wikisync {
    $scriptPath = Join-Path $script:Root 'scripts' 'wiki-sync.ps1'
    & $script:Pwsh -NoLogo -File $scriptPath sync
    exit $LASTEXITCODE
}

function Invoke-Wikipush {
    $scriptPath = Join-Path $script:Root 'scripts' 'wiki-sync.ps1'
    & $script:Pwsh -NoLogo -File $scriptPath push
    exit $LASTEXITCODE
}

function Invoke-Wikiupdate {
    # Call as separate child pwsh runs so each sub-script's exit doesn't
    # tear down our own dispatcher mid-sequence.
    $scriptPath = Join-Path $script:Root 'scripts' 'wiki-sync.ps1'
    & $script:Pwsh -NoLogo -File $scriptPath sync
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $script:Pwsh -NoLogo -File $scriptPath push
    exit $LASTEXITCODE
}

function Invoke-Clean {
    Invoke-Smokeclean
    $cache = Join-Path $HOME '.ca-bootstrap' 'cache'
    if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
    Write-Ok 'Cleaned cache and smoke state'
}

function Invoke-Release {
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
    $scriptPath = Join-Path $script:Root 'scripts' 'release.ps1'
    $argList = @('-Version', $Version)
    if ($NotesFile)        { $argList += @('-NotesFile', $NotesFile) }
    if ($SkipSmoke)        { $argList += '-SkipSmoke' }
    if ($SkipTests)        { $argList += '-SkipTests' }
    if ($SkipManifestEdit) { $argList += '-SkipManifestEdit' }
    if ($DryRun)           { $argList += '-DryRun' }
    if ($Confirm)          { $argList += '-Confirm' }
    & $script:Pwsh -NoLogo -File $scriptPath @argList
    exit $LASTEXITCODE
}

function Invoke-Releasedryrun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [string]$NotesFile
    )
    Invoke-Release -Version $Version -NotesFile $NotesFile -DryRun
}

function Invoke-Releasefull {
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
    $scriptPath = Join-Path $script:Root 'scripts' 'release-full.ps1'
    $argList = @('-Version', $Version)
    if ($NotesFile)        { $argList += @('-NotesFile', $NotesFile) }
    if ($SkipSmoke)        { $argList += '-SkipSmoke' }
    if ($SkipTests)        { $argList += '-SkipTests' }
    if ($SkipManifestEdit) { $argList += '-SkipManifestEdit' }
    if ($DryRun)           { $argList += '-DryRun' }
    if ($Confirm)          { $argList += '-Confirm' }
    & $script:Pwsh -NoLogo -File $scriptPath @argList
    exit $LASTEXITCODE
}

function Invoke-Releasefulldryrun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [string]$NotesFile
    )
    Invoke-Releasefull -Version $Version -NotesFile $NotesFile -DryRun
}

function Invoke-Tag {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )
    if (-not $Version) {
        Write-Bad '-Version is required, e.g. ./make.ps1 tag -Version v1.0.0'
        exit 1
    }
    if ($Version -notmatch '^v') { $Version = "v$Version" }
    git tag -a $Version -m "Release $Version"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    git push origin $Version
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Ok "Tagged $Version and pushed"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

# Normalize: accept both 'help' and '--help'/'-h' as the help target. PowerShell
# never reaches a positional 'help' for --help because [CmdletBinding] eats the
# unknown switch first; intercept here so `./make.ps1 --help` still works.
if ($Target -in @('--help', '-h', '/?', '/h')) { $Target = 'help' }

if (-not $script:TargetDescriptions.Contains($Target)) {
    Write-Bad "Unknown target: $Target"
    Write-Host ''
    Invoke-Help
    exit 2
}

$fnName = Convert-TargetToFunctionName -T $Target
$fn = Get-Command -Name $fnName -CommandType Function -ErrorAction SilentlyContinue
if (-not $fn) {
    Write-Bad "Internal error: no function $fnName for target '$Target'"
    exit 99
}

# Splat the remaining args at the per-target function. PowerShell will re-parse
# strings like '-Tool', 'dotnet-10' against the function's [param()] block, so
# `./make.ps1 tool-install -Tool dotnet-10` binds correctly to Invoke-Toolinstall.
if ($RemainingArgs) {
    & $fn @RemainingArgs
}
else {
    & $fn
}
exit $LASTEXITCODE
