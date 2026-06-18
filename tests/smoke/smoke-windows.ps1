<#
.SYNOPSIS
  Live Windows smoke test for ca-bootstrap — AB#40188 / AB#40189.
  Version-agnostic: it exercises whatever ca-bootstrap.exe is passed via -Exe
  (or sits next to this script) and prints that build's version line in the
  summary, so it never needs editing per release.

.DESCRIPTION
  Exercises the paths never run on real Windows: doctor detection, the setup
  wizard (identity + folder taxonomy), repair's winget dispatch, and undo's
  reverser walk (seed_readme -> create_folder ordering, identity restore).

  SAFE BY DEFAULT:
    * Runs entirely in a throwaway sandbox under %TEMP%.
    * Redirects USERPROFILE for the child process so the action journal, lock,
      and audit snapshots live in the sandbox — your real ~/.ca-bootstrap
      journal is never read or written, so `undo` cannot touch real history.
    * `setup` writes folders + git identity into the sandbox workspace, not
      your real ChannelAssistDev.
    * `repair` is tested against an already-installed REQUIRED tool (no-op
      path) — it does NOT install anything unless you pass -FullInstallTest.

  -FullInstallTest opts into the genuinely mutating leg: a real
  `winget install jqlang.jq` followed by `undo --include-tools` to uninstall
  it. Only use this if installing/removing jq on this machine is acceptable.

.PARAMETER Exe
  Path to ca-bootstrap.exe. Defaults to .\ca-bootstrap.exe next to this script.

.PARAMETER FullInstallTest
  Also run a real winget install of jq and uninstall it via undo.

.PARAMETER KeepSandbox
  Leave the sandbox directory on disk for inspection (default: removed).

.EXAMPLE
  .\smoke-windows.ps1
  .\smoke-windows.ps1 -FullInstallTest
#>
[CmdletBinding()]
param(
  [string]$Exe = (Join-Path $PSScriptRoot 'ca-bootstrap.exe'),
  [switch]$FullInstallTest,
  [switch]$KeepSandbox
)

$ErrorActionPreference = 'Stop'

# Decode the child process's UTF-8 stdout correctly when captured via the
# pipeline (otherwise ✓/⚠/→/— show up as mojibake like "Γ£ô").
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

$results = [ordered]@{}
function Record($name, $ok, $detail) {
  $results[$name] = [pscustomobject]@{ Pass = [bool]$ok; Detail = $detail }
  $tag = if ($ok) { 'PASS' } else { 'FAIL' }
  Write-Host ("[{0}] {1} — {2}" -f $tag, $name, $detail)
}
function RunExe([string[]]$ExeArgs) {
  $out = & $Exe @ExeArgs 2>&1 | Out-String
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

if (-not (Test-Path $Exe)) { throw "ca-bootstrap.exe not found at: $Exe" }

# --- sandbox + isolation ------------------------------------------------------
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$sandbox   = Join-Path $env:TEMP ("ca-bootstrap-smoke-" + $stamp)
$home_iso  = Join-Path $sandbox 'home'          # becomes USERPROFILE (journal lives here)
$workspace = Join-Path $sandbox 'workspace'
New-Item -ItemType Directory -Force -Path $home_iso, $workspace | Out-Null
$transcript = Join-Path $sandbox 'transcript.txt'
Start-Transcript -Path $transcript -Force | Out-Null

$origUserProfile = $env:USERPROFILE
$origHome        = $env:HOME
$env:USERPROFILE = $home_iso   # Go's os.UserHomeDir() reads USERPROFILE on Windows
$env:HOME        = $home_iso   # belt-and-suspenders

# YAML uses forward slashes to avoid backslash-escape pitfalls (Go accepts them on Windows).
$wsYaml = ($workspace -replace '\\','/')

@"
welcome:
  consent: true
prereqs:
  continue_with_drift: true
identity:
  name: "Smoke Test"
  email: "smoke@example.com"
  workspace_root: "$wsYaml"
folders:
  continue: true
repos:
  group:
    smoke: true
extras:
  vscode_workspace_file: true
  vscode_defaults: true
  ca_claude_plugin: true
  ca_copilot_plugin: false
"@ | Set-Content -Path (Join-Path $sandbox 'setup.yaml') -Encoding utf8

# Minimal repos manifest for the smoke: one group, one repo that lands in
# ca-platform/ca-claude-plugin so the extras step's plugin-link (junction
# on Windows — the genuine Windows-specific leg) actually fires. The clone
# itself is mocked (CA_BOOTSTRAP_CLONE_MOCK below) so the smoke stays
# offline/fast; the junction it creates afterwards is REAL.
@"
version: 1
default_protocol: https
groups:
  - name: smoke
    repos:
      - { repo: ChannelAssist/ca-claude-plugin, into: ca-platform/ca-claude-plugin, branch: dev }
"@ | Set-Content -Path (Join-Path $sandbox 'repos.yaml') -Encoding utf8

@"
repair:
  elevation_action: allow
"@ | Set-Content -Path (Join-Path $sandbox 'repair.yaml') -Encoding utf8

@"
undo:
  proceed: true
  uninstall:
    jq: true
"@ | Set-Content -Path (Join-Path $sandbox 'undo.yaml') -Encoding utf8

$journal = Join-Path $home_iso '.ca-bootstrap\journal.ndjson'

try {
  Write-Host "=== ca-bootstrap Windows smoke test ===`nSandbox: $sandbox`n"

  # 1) version
  $r = RunExe @('version')
  Record 'version' ($r.Code -eq 0 -and $r.Out -match 'ca-bootstrap .*commit.*built') $r.Out.Trim()

  # 2) doctor (read-only). Exit 0 (all present) or 2 (a required tool missing/old)
  #    are both "ran correctly"; exit 1 means a manifest/IO error = real failure.
  $r = RunExe @('doctor')
  Record 'doctor' ($r.Code -ne 1) ("exit=$($r.Code) (0=all ok, 2=a required tool missing/below-min — both fine)")
  Write-Host $r.Out

  # 3) setup (unattended) — full wizard: welcome→prereqs→gh-auth→identity
  #    →folders→repos→extras. Seams: gh-auth mocked (real login is
  #    interactive-only), clone mocked (offline/fast), WSL mocked-present
  #    (so its offer is skipped, not installed live). The .vscode defaults,
  #    workspace file, and the ca-claude-plugin JUNCTION are all REAL.
  $env:CA_BOOTSTRAP_GH_MOCK    = 'authed:smoke'
  $env:CA_BOOTSTRAP_REPOS      = (Join-Path $sandbox 'repos.yaml')
  $env:CA_BOOTSTRAP_CLONE_MOCK = 'ok'
  $env:CA_BOOTSTRAP_WSL_MOCK   = 'has-ubuntu'
  $r = RunExe @('setup','--unattended','--config',(Join-Path $sandbox 'setup.yaml'))
  $caTools    = Join-Path $workspace 'ca-tools'
  $caReadme   = Join-Path $caTools 'README.md'
  $gitcfg     = Join-Path $workspace '.git\config'
  $clone      = Join-Path $workspace 'ca-platform\ca-claude-plugin'
  $wsFile     = Join-Path $workspace 'ChannelAssist.code-workspace'
  $vscode     = Join-Path $workspace '.vscode\settings.json'
  $junction   = Join-Path $home_iso '.claude\plugins\ca-claude-plugin'
  $idOk       = (Test-Path $gitcfg) -and ((Get-Content $gitcfg -Raw) -match 'Smoke Test')
  $setupOk    = ($r.Code -eq 0) -and (Test-Path $caTools) -and (Test-Path $caReadme) -and $idOk `
                -and (Test-Path $clone) -and (Test-Path $wsFile) -and (Test-Path $vscode) -and (Test-Path $junction)
  Record 'setup' $setupOk ("exit=$($r.Code); folders=$([bool](Test-Path $caTools)); identity=$idOk; clone=$([bool](Test-Path $clone)); code-workspace=$([bool](Test-Path $wsFile)); .vscode=$([bool](Test-Path $vscode)); plugin-junction=$([bool](Test-Path $junction))")
  Write-Host $r.Out

  # 4) repair no-op against an already-installed required tool (git). Validates
  #    detection + dispatch WITHOUT mutating the machine. Exit 0 expected.
  $r = RunExe @('repair','--target','git','--unattended','--config',(Join-Path $sandbox 'repair.yaml'))
  Record 'repair (git no-op)' ($r.Code -eq 0) ("exit=$($r.Code) — expected 'already installed' no-op")
  Write-Host $r.Out

  # 5) OPTIONAL: real winget install of jq, then uninstall via undo
  if ($FullInstallTest) {
    $r = RunExe @('repair','--target','jq','--unattended','--config',(Join-Path $sandbox 'repair.yaml'))
    $jqPresent = $null -ne (Get-Command jq -ErrorAction SilentlyContinue)
    Record 'repair (jq install)' (($r.Code -eq 0) -and $jqPresent) ("exit=$($r.Code); jq on PATH=$jqPresent")
    Write-Host $r.Out
  } else {
    Write-Host "[SKIP] full winget install/uninstall (pass -FullInstallTest to run jq install + undo)`n"
  }

  # 6) undo (unattended, --force --include-folders) — reverses the whole
  #    session: plugin junction, .vscode + workspace files (create_file),
  #    the clone (clone_repo), seeded READMEs, folders, and git identity.
  #    --include-folders is needed to remove the populated clone + folders.
  #    With -FullInstallTest, also --include-tools to uninstall jq.
  $undoArgs = @('undo','--unattended','--force','--include-folders','--config',(Join-Path $sandbox 'undo.yaml'))
  if ($FullInstallTest) { $undoArgs += '--include-tools' }
  $r = RunExe $undoArgs
  $foldersGone = -not (Test-Path $caTools)
  $cloneGone   = -not (Test-Path $clone)
  $wsFileGone  = -not (Test-Path $wsFile)
  $junctionGone = -not (Test-Path $junction)
  $idCleared   = -not ((Test-Path $gitcfg) -and ((Get-Content $gitcfg -Raw) -match 'Smoke Test'))
  $snapshot    = Test-Path (Join-Path $home_iso '.ca-bootstrap\journal.ndjson.undone-*')
  $undoneMarks = (Test-Path $journal) -and ((Get-Content $journal -Raw) -match 'entry_undone')
  $undoOk = ($r.Code -eq 0) -and $foldersGone -and $cloneGone -and $wsFileGone -and $junctionGone -and $idCleared -and $undoneMarks -and $snapshot
  Record 'undo' $undoOk ("exit=$($r.Code); folders=$foldersGone; clone=$cloneGone; code-workspace=$wsFileGone; plugin-junction=$junctionGone; identity=$idCleared; entry_undone=$undoneMarks; snapshot=$snapshot")
  Write-Host $r.Out
}
finally {
  $env:USERPROFILE = $origUserProfile
  $env:HOME        = $origHome
  foreach ($v in 'CA_BOOTSTRAP_GH_MOCK','CA_BOOTSTRAP_REPOS','CA_BOOTSTRAP_CLONE_MOCK','CA_BOOTSTRAP_WSL_MOCK') {
    Remove-Item "Env:$v" -ErrorAction SilentlyContinue
  }
  # Stop-Transcript throws if no transcript is running (e.g. Start-Transcript
  # failed); swallow it so it never masks the real failure from the try block.
  try { Stop-Transcript | Out-Null } catch {}
}

# --- summary (paste this block back) -----------------------------------------
$pass = ($results.Values | Where-Object { $_.Pass }).Count
$tot  = $results.Count
Write-Host "`n================ SMOKE SUMMARY ($pass/$tot passed) ================"
foreach ($k in $results.Keys) {
  $v = $results[$k]
  Write-Host ("{0,-22} {1}  {2}" -f $k, $(if ($v.Pass){'PASS'}else{'FAIL'}), $v.Detail)
}
Write-Host "Exe        : $Exe"
Write-Host "Version    : $((RunExe @('version')).Out.Trim())"
Write-Host "Transcript : $transcript"
Write-Host "Sandbox    : $sandbox"
Write-Host "==================================================================="

if (-not $KeepSandbox) {
  Remove-Item -Recurse -Force $sandbox -ErrorAction SilentlyContinue
  Write-Host "(sandbox removed; pass -KeepSandbox to retain it)"
}
if ($pass -lt $tot) { exit 1 } else { exit 0 }
