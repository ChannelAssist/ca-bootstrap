#requires -Version 7.0
# steps/15-platform-check.ps1 — Windows pre-install readiness audit.
#
# Runs after welcome (consent), before workspace (commitment), so the
# user sees show-stoppers and warnings before they invest time picking
# a workspace folder or waiting on installs. On non-Windows hosts the
# step is a no-op (skip status); macOS/Linux have their own conventions
# and the package managers there fail loudly enough that an explicit
# pre-flight adds noise.

function Test-CABStep15 {
    [CmdletBinding()]
    param([hashtable]$Context)
    if ((Get-CABOSFamily) -ne 'windows') {
        return @{ status = 'skip'; details = 'Pre-flight only runs on Windows.' }
    }
    @{ status = 'pending'; details = 'Pre-flight audit pending.' }
}

# --- Individual probes -----------------------------------------------------
#
# Each probe returns @{
#   status      = 'ok' | 'warn' | 'fail'
#   name        = display name
#   details     = what we found
#   remediation = actionable hint (empty when status='ok')
# }
#
# A 'fail' here never aborts setup — it surfaces a likely-blocking issue
# so the user can fix it before tool installs start failing. The wizard
# continues either way (per the "don't bork on failure" directive); the
# user can re-run `ca-bootstrap.ps1 setup` after remediating.

function Test-CABWingetPresent {
    if (Get-Command 'winget' -ErrorAction SilentlyContinue) {
        $v = (& winget --version 2>$null) -join ''
        return @{ status = 'ok'; name = 'winget on PATH'; details = $v; remediation = '' }
    }
    @{
        status      = 'fail'
        name        = 'winget on PATH'
        details     = 'winget not found'
        remediation = 'Install "App Installer" from the Microsoft Store (winget ships with it). On stock Win11 it should already be present; if not, see https://aka.ms/getwinget.'
    }
}

function Test-CABNpmPresent {
    [CmdletBinding()]
    param([hashtable]$Context)
    # Only warn-worthy if the manifest plans an npm install on this host.
    $manifest = Read-CABManifest -Path (Join-Path $Context.RepoRoot 'manifest/tools.yaml') -Quiet
    $os = Get-CABOSFamily
    $needsNpm = @(@($manifest.required) + @($manifest.optional)) | Where-Object {
        $entry = Get-CABInstallEntry -Tool $_ -OSFamily $os
        $entry -and $entry.type -eq 'npm'
    }
    if (-not $needsNpm) {
        return @{ status = 'ok'; name = 'npm (not required by manifest)'; details = 'no npm-installed tools planned'; remediation = '' }
    }
    if (Get-Command 'npm' -ErrorAction SilentlyContinue) {
        $v = (& npm --version 2>$null) -join ''
        return @{ status = 'ok'; name = 'npm on PATH'; details = "v$v ($($needsNpm.Count) npm tool(s) planned)"; remediation = '' }
    }
    @{
        status      = 'warn'
        name        = 'npm on PATH'
        details     = "missing, but $($needsNpm.Count) npm tool(s) planned ($((@($needsNpm).id) -join ', '))"
        remediation = 'npm ships with Node.js. The prereqs step will install Node.js; npm will become available after that. If you want to install Claude Code or other npm tools manually first, install Node.js LTS via `winget install OpenJS.NodeJS.LTS`.'
    }
}

function Test-CABExecutionPolicy {
    $cu = Get-ExecutionPolicy -Scope CurrentUser
    $lm = Get-ExecutionPolicy -Scope LocalMachine
    # Effective policy: more restrictive of CU/LM (but `Undefined` falls through).
    $effective = Get-ExecutionPolicy
    if ($effective -in 'Restricted','AllSigned') {
        return @{
            status      = 'fail'
            name        = 'PowerShell ExecutionPolicy'
            details     = "effective=$effective (CU=$cu, LM=$lm)"
            remediation = 'Some install scripts won''t run. Set CurrentUser to RemoteSigned: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`'
        }
    }
    @{ status = 'ok'; name = 'PowerShell ExecutionPolicy'; details = "effective=$effective"; remediation = '' }
}

function Test-CABElevation {
    # Warn-only by design: most installs run fine as a regular user
    # (winget user-scope, npm -g into AppData, etc.). MSI-based installs
    # may UAC-prompt mid-run; we want the user to know that's coming.
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        return @{ status = 'ok'; name = 'Elevation'; details = 'running as Administrator'; remediation = '' }
    }
    @{
        status      = 'warn'
        name        = 'Elevation'
        details     = 'running as standard user'
        remediation = 'Most installs work as a normal user. If an MSI install prompts for UAC, accept it; if you''d rather avoid the prompts, relaunch pwsh as Administrator.'
    }
}

function Test-CABDefender {
    # Defender RT-scanning during install can lock files mid-write and
    # slow things down considerably. Probe via Get-MpPreference; the
    # cmdlet is missing on Server SKUs or when Defender is replaced by
    # another AV, in which case we just skip the check.
    if (-not (Get-Command 'Get-MpPreference' -ErrorAction SilentlyContinue)) {
        return @{ status = 'ok'; name = 'Defender real-time scan'; details = 'Get-MpPreference unavailable (likely 3rd-party AV)'; remediation = '' }
    }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        if ($pref.DisableRealtimeMonitoring) {
            return @{ status = 'ok'; name = 'Defender real-time scan'; details = 'disabled'; remediation = '' }
        }
        return @{
            status      = 'warn'
            name        = 'Defender real-time scan'
            details     = 'enabled (installs may be slower)'
            remediation = 'Optional: add the workspace root + %LOCALAPPDATA%\Microsoft\WinGet to Defender exclusions for faster installs. Not required.'
        }
    } catch {
        return @{ status = 'ok'; name = 'Defender real-time scan'; details = 'unreadable (no permission)'; remediation = '' }
    }
}

function Test-CABWingetSource {
    if (-not (Get-Command 'winget' -ErrorAction SilentlyContinue)) {
        return @{ status = 'skip'; name = 'winget sources'; details = 'skipped (winget missing)'; remediation = '' }
    }
    $output = & winget source list 2>&1 | Out-String
    if ($output -notmatch '(?im)^\s*winget\b') {
        return @{
            status      = 'fail'
            name        = 'winget sources'
            details     = 'default `winget` source not registered'
            remediation = 'Restore the default source: `winget source reset --force`'
        }
    }
    @{ status = 'ok'; name = 'winget sources'; details = 'default `winget` source registered'; remediation = '' }
}

function Test-CABTempWritable {
    $temp = [IO.Path]::GetTempPath()
    $probe = Join-Path $temp ("cab-preflight-{0}.tmp" -f ([Guid]::NewGuid().ToString('N').Substring(0,8)))
    try {
        Set-Content -Path $probe -Value 'ok' -ErrorAction Stop
        Remove-Item -Path $probe -ErrorAction SilentlyContinue
        return @{ status = 'ok'; name = '%TEMP% writable'; details = $temp; remediation = '' }
    } catch {
        return @{
            status      = 'fail'
            name        = '%TEMP% writable'
            details     = "$temp — $($_.Exception.Message)"
            remediation = 'Many installers stage to %TEMP%. Free disk, fix permissions, or set TEMP/TMP to a writable directory.'
        }
    }
}

function Test-CABMsiCache {
    # %WINDIR%\Installer is the system-owned MSI cache; on a healthy box
    # it exists and is writable only by SYSTEM/Administrators. We're not
    # checking write access (we can't, as user) — we verify the directory
    # exists and isn't marked read-only at the dir attribute level, which
    # is a known sign of a corrupted Windows install or aggressive policy.
    $msi = Join-Path $env:WINDIR 'Installer'
    if (-not (Test-Path $msi)) {
        return @{
            status      = 'warn'
            name        = 'MSI cache directory'
            details     = "missing: $msi"
            remediation = 'Some MSI installs may fail. Usually self-repairs on first MSI install — proceed and watch for explicit errors.'
        }
    }
    $attr = (Get-Item $msi -Force).Attributes
    if ($attr -band [IO.FileAttributes]::ReadOnly) {
        return @{
            status      = 'warn'
            name        = 'MSI cache directory'
            details     = 'present but marked ReadOnly'
            remediation = 'Run `attrib -r %WINDIR%\Installer` from an elevated prompt if MSI installs fail.'
        }
    }
    @{ status = 'ok'; name = 'MSI cache directory'; details = $msi; remediation = '' }
}

# --- Step entry ------------------------------------------------------------

function Invoke-CABStep15 {
    [CmdletBinding()]
    param([hashtable]$Context)

    $stepNum  = $Context.StepOrdinal ?? 2
    $stepTotal = $Context.TotalSteps  ?? 9
    Write-CABStep -Number $stepNum -Total $stepTotal -Title 'Platform readiness'

    if ((Get-CABOSFamily) -ne 'windows') {
        Write-CABStatus -Status skip -Message 'Non-Windows host — pre-flight skipped.'
        return @{ status = 'skip'; details = 'Pre-flight only runs on Windows.' }
    }

    # Run probes. Order: cheap PATH checks first so the user sees signal
    # immediately; the slower winget/Defender probes come after.
    $probes = @(
        (Test-CABWingetPresent),
        (Test-CABNpmPresent     -Context $Context),
        (Test-CABExecutionPolicy),
        (Test-CABElevation),
        (Test-CABWingetSource),
        (Test-CABTempWritable),
        (Test-CABMsiCache),
        (Test-CABDefender)
    )

    foreach ($p in $probes) {
        $detail = if ($p.details) { $p.details } else { '' }
        Write-CABStatus -Status $p.status -Message $p.name -Detail $detail
        if ($p.status -ne 'ok' -and $p.remediation) {
            Write-Host "      → $($p.remediation)" -ForegroundColor DarkGray
        }
    }
    Write-Host ''

    $fails = @($probes | Where-Object { $_.status -eq 'fail' })
    $warns = @($probes | Where-Object { $_.status -eq 'warn' })

    # Expose results so downstream steps can introspect (e.g., 20-prereqs
    # can skip the winget install path if winget is missing).
    $Context.PlatformReadiness = @{
        probes = $probes
        fails  = $fails
        warns  = $warns
    }

    if ($fails.Count -eq 0 -and $warns.Count -eq 0) {
        return @{ status = 'ok'; details = "All $($probes.Count) checks passed." }
    }

    # Even on failure, return 'warn' (not 'fail') — per the directive,
    # we don't abort setup. The user sees the issues, has remediation
    # hints, and can decide to proceed or quit at the next prompt.
    if ($fails.Count -gt 0) {
        $proceed = Read-CABConfirm `
            -Question "$($fails.Count) blocking issue(s) detected. Proceed anyway?" `
            -Default $false `
            -AnswerKey 'platform-check.proceed_with_fails'
        if ((Test-CABQuit $proceed) -or (Test-CABNo $proceed)) {
            return @{ status = 'quit'; details = "User declined to proceed with $($fails.Count) blocking pre-flight issue(s)." }
        }
        return @{
            status  = 'warn'
            details = "$($fails.Count) blocking + $($warns.Count) advisory issue(s); user opted to continue."
        }
    }

    @{
        status  = 'warn'
        details = "$($warns.Count) advisory issue(s); none blocking."
    }
}

function Undo-CABStep15 {
    @{ status = 'noop'; details = 'Pre-flight is read-only; nothing to reverse.' }
}

# Functions exported automatically when this file is dot-sourced.
