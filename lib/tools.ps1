#requires -Version 7.0
# lib/tools.ps1 — generic tool detection.
#
# A "tool" is any entry in manifest/tools.yaml. Detection runs the entry's
# check.cmd, optionally extracts a version via check.version_regex, and
# compares against check.min_version. Result shape:
#
#   @{
#     id       = 'dotnet-10'
#     name     = '.NET SDK 10'
#     status   = 'ok' | 'warn' | 'fail' | 'na' | 'error'
#     found    = '10.0.100'  # version string, when extracted
#     required = '10.x'       # min_version, when present
#     details  = '...'         # human-readable
#   }

function Test-CABTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Tool)

    $result = @{
        id       = $Tool.id
        name     = $Tool.name
        status   = 'fail'
        found    = $null
        required = $null
        details  = $null
    }
    if ($Tool.check -and $Tool.check.min_version) {
        $result.required = $Tool.check.min_version
    }

    # Platform restriction (e.g. wsl is windows-only).
    if ($Tool.platform) {
        $os = Get-CABOSFamily
        if ($Tool.platform -eq 'windows-only' -and $os -ne 'windows') {
            $result.status = 'na'
            $result.details = 'Windows-only; not applicable on this OS.'
            return $result
        }
        if ($Tool.platform -eq 'macos-only' -and $os -ne 'macos') {
            $result.status = 'na'
            $result.details = 'macOS-only; not applicable on this OS.'
            return $result
        }
    }

    if (-not $Tool.check -or -not $Tool.check.cmd) {
        # Meta-tools (e.g. vscode-extensions) declare requirements via the
        # `requires` field instead of a check.cmd. Treat as ok unless their
        # required tool is missing.
        if ($Tool.requires) {
            $result.status = 'ok'
            $result.details = "Depends on: $($Tool.requires -join ', ') (detected separately)"
            return $result
        }
        $result.status = 'error'
        $result.details = 'Manifest entry has no check.cmd.'
        return $result
    }

    $cmdParts = $Tool.check.cmd -split '\s+', 2
    $exe = $cmdParts[0]
    # Renamed from $args to avoid shadowing the PowerShell automatic
    # variable (PSAvoidAssignmentToAutomaticVariable). $args is the
    # parameter array of the enclosing scriptblock; assigning to it
    # corrupts the enclosing function's view of its own arguments.
    $cmdArgs = if ($cmdParts.Count -gt 1) { $cmdParts[1] } else { $null }

    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        $result.status = 'fail'
        $result.details = 'Not installed (executable not on PATH).'
        return $result
    }

    try {
        $output = if ($cmdArgs) {
            (& $exe $cmdArgs.Split(' ') 2>&1) -join "`n"
        } else {
            (& $exe 2>&1) -join "`n"
        }
    } catch {
        $result.status = 'error'
        $result.details = "check.cmd threw: $($_.Exception.Message)"
        return $result
    }

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        $result.status = 'fail'
        $result.details = "check.cmd exited $LASTEXITCODE."
        return $result
    }

    # If no version_regex, presence is enough.
    if (-not $Tool.check.version_regex) {
        $result.status = 'ok'
        $result.details = 'Installed.'
        return $result
    }

    # Apply regex per-line (some tools like dotnet --list-sdks emit many).
    # Prefer capture group 1 (most regexes use one); fall back to the whole
    # match so manifest authors aren't forced to add parens to a tight regex.
    $found = $null
    foreach ($line in ($output -split "`n")) {
        if ($line -match $Tool.check.version_regex) {
            $found = if ($Matches.Count -gt 1) { $Matches[1] } else { $Matches[0] }
            break
        }
    }

    if (-not $found) {
        $result.status = 'fail'
        if ($result.required) {
            $result.details = "Installed, but no version matching $($result.required) found."
        } else {
            $result.details = "Installed, but version could not be parsed."
        }
        return $result
    }
    $result.found = $found

    if (-not $result.required) {
        $result.status = 'ok'
        $result.details = "Installed: $found"
        return $result
    }

    if (Compare-CABVersion -Found $found -Required $result.required) {
        $result.status = 'ok'
        $result.details = "$found (≥ $($result.required))"
    } else {
        $result.status = 'warn'
        $result.details = "$found is older than required $($result.required)"
    }
    return $result
}

# Compare-CABVersion — returns $true if $Found is >= $Required.
#   Both arguments are version strings; they are normalized to a 3-segment
#   form before [version] comparison so "20" works against "20.11.0".
function Compare-CABVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Found,
        [Parameter(Mandatory)][string]$Required
    )
    function NormalizeVer([string]$v) {
        # Strip leading 'v', drop pre-release/build suffix.
        $v = $v -replace '^[vV]', '' -replace '[-+].*$',''
        $parts = $v -split '\.'
        while ($parts.Count -lt 3) { $parts += '0' }
        if ($parts.Count -gt 3) { $parts = $parts[0..2] }
        return ($parts -join '.')
    }
    try {
        $a = [version](NormalizeVer $Found)
        $b = [version](NormalizeVer $Required)
        return ($a -ge $b)
    } catch {
        # Fallback: lexical compare.
        return ($Found -ge $Required)
    }
}

# Get-CABToolReport — runs Test-CABTool over a manifest, returns an array
# of result hashtables. The doctor command renders this; the prereq step
# calls it during setup.
function Get-CABToolReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ManifestPath)
    $manifest = Read-CABManifest -Path $ManifestPath
    $all = @()
    foreach ($t in @($manifest.required)) { $all += @{ tool = $t; required = $true } }
    foreach ($t in @($manifest.optional)) { $all += @{ tool = $t; required = $false } }

    $results = @()
    foreach ($entry in $all) {
        $r = Test-CABTool -Tool $entry.tool
        $r.is_required = $entry.required
        $results += $r
    }
    return $results
}

# Format-CABToolReport — pretty-print the tool report to console.
function Format-CABToolReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][array]$Report)

    Write-Host '  Required:'
    foreach ($r in ($Report | Where-Object { $_.is_required })) {
        Write-CABToolLine $r
    }
    Write-Host '  Optional:'
    foreach ($r in ($Report | Where-Object { -not $_.is_required })) {
        Write-CABToolLine $r
    }
}

function Write-CABToolLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)
    $icon, $color = switch ($Result.status) {
        'ok'    { '✓', 'Green'    }
        'warn'  { '⚠', 'Yellow'   }
        'fail'  { '✗', 'Red'      }
        'na'    { '–', 'DarkGray' }
        'error' { '!', 'Magenta'  }
        default { '?', 'White'    }
    }
    $label = "$($Result.id)".PadRight(20)
    Write-CABColor ([ConsoleColor]$color) "    $icon  $label  $($Result.details)"
}

# Install-CABTool — dispatch a single tool's install entry based on OS.
#   Returns @{ ok = $bool; details = '...' }.
#   Honors $Context.WhatIfMode to dry-run.
function Install-CABTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tool,
        [hashtable]$Context = @{}
    )

    $osFamily = Get-CABOSFamily
    $entry = Get-CABInstallEntry -Tool $Tool -OSFamily $osFamily
    if (-not $entry) {
        return @{ ok = $false; details = "No install method for $($Tool.id) on $osFamily" }
    }

    # Meta-tool: install_method drives a different code path.
    if ($Tool.install_method -eq 'code-cli') {
        return Install-CABVSCodeExtension -Tool $Tool -Context $Context
    }

    $type = $entry.type
    $id   = $entry.id

    if ($Context.WhatIfMode) {
        return @{ ok = $true; details = "WhatIf: would install $($Tool.id) via $type ($id)" }
    }

    Write-Host "    → $type install: $id" -NoNewline

    $cmdResult = $null
    try {
        switch ($type) {
            'winget' {
                & winget install --id $id --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Host
                $cmdResult = $LASTEXITCODE
            }
            'brew' {
                if ($entry.cask) {
                    & brew install --cask $id 2>&1 | Out-Host
                } else {
                    & brew install $id 2>&1 | Out-Host
                }
                $cmdResult = $LASTEXITCODE
            }
            'apt' {
                if ($entry.repo_setup) {
                    $repoScript = Join-Path $Context.RepoRoot $entry.repo_setup
                    if (Test-Path $repoScript) { & bash $repoScript | Out-Host }
                }
                & sudo apt-get update 2>&1 | Out-Host
                $idArgs = $id -split ' '
                & sudo apt-get install -y @idArgs 2>&1 | Out-Host
                $cmdResult = $LASTEXITCODE
            }
            'dnf' {
                $idArgs = $id -split ' '
                & sudo dnf install -y @idArgs 2>&1 | Out-Host
                $cmdResult = $LASTEXITCODE
            }
            'snap' {
                if ($entry.classic) {
                    & sudo snap install --classic $id 2>&1 | Out-Host
                } else {
                    & sudo snap install $id 2>&1 | Out-Host
                }
                $cmdResult = $LASTEXITCODE
            }
            'nvm' {
                # nvm is a shell function, not a binary — invoke via a
                # subshell that loads the user's nvm setup.
                $cmd = "source `"$HOME/.nvm/nvm.sh`" && nvm install $($entry.version)"
                & bash -lc $cmd 2>&1 | Out-Host
                $cmdResult = $LASTEXITCODE
            }
            'npm' {
                $globalFlag = if ($entry.global) { '-g' } else { $null }
                & npm install $globalFlag $id 2>&1 | Out-Host
                $cmdResult = $LASTEXITCODE
            }
            'gh-extension' {
                # `gh extension install OWNER/REPO` is idempotent in spirit
                # but exits non-zero when the extension is already present.
                # Probe `gh extension list` first so the wizard doesn't
                # report "failed" on an already-installed extension.
                if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
                    # Emit the trailing newline for the "→ $type install: $id"
                    # prefix Write-Host'ed above (with -NoNewline) so the
                    # post-return console output isn't crammed onto the
                    # same line.
                    Write-Host ''
                    return @{ ok = $false; details = 'gh CLI not on PATH; install gh first' }
                }
                $shortName = ($id -split '/')[-1]
                # `gh extension list` emits one tab-separated row per
                # installed extension; the second column is owner/repo.
                # Match exactly on that column so a forked extension
                # (e.g. some-fork/gh-copilot-helper) and substring
                # collisions elsewhere in the output don't trick us into
                # `upgrade` when the target isn't actually installed.
                $listOutput = & gh extension list 2>&1
                $alreadyInstalled = $false
                if ($LASTEXITCODE -eq 0) {
                    foreach ($row in @($listOutput -split "`r?`n")) {
                        $cols = $row -split "`t"
                        if (@($cols).Count -ge 2 -and $cols[1].Trim() -ieq $id) {
                            $alreadyInstalled = $true
                            break
                        }
                    }
                }
                if ($alreadyInstalled) {
                    Write-Host " (already installed; upgrading)" -NoNewline
                    & gh extension upgrade $shortName 2>&1 | Out-Host
                    $cmdResult = $LASTEXITCODE
                } else {
                    & gh extension install $id 2>&1 | Out-Host
                    $cmdResult = $LASTEXITCODE
                }
            }
            'script' {
                $tmpScript = New-TemporaryFile
                try {
                    Invoke-WebRequest -Uri $entry.url -OutFile $tmpScript -UseBasicParsing
                    if ($entry.args) {
                        & bash $tmpScript ($entry.args -split ' ') 2>&1 | Out-Host
                    } else {
                        & bash $tmpScript 2>&1 | Out-Host
                    }
                    $cmdResult = $LASTEXITCODE
                } finally {
                    Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
                }
            }
            'command' {
                # Avoid Invoke-Expression (PSAvoidUsingInvokeExpression).
                # Manifest install commands are space-delimited
                # invocations like "winget install Foo.Bar --silent";
                # split into command + args and call & directly.
                $cmdParts = $entry.cmd -split '\s+'
                $exe = $cmdParts[0]
                $exeArgs = if ($cmdParts.Count -gt 1) { $cmdParts[1..($cmdParts.Count - 1)] } else { @() }
                & $exe @exeArgs 2>&1 | Out-Host
                $cmdResult = $LASTEXITCODE
            }
            default {
                return @{ ok = $false; details = "Unknown install type: $type" }
            }
        }
    } catch {
        return @{ ok = $false; details = "Install threw: $($_.Exception.Message)" }
    }

    Write-Host ''
    if ($cmdResult -ne 0 -and $null -ne $cmdResult) {
        return @{ ok = $false; details = "$type install exited $cmdResult" }
    }

    # post_install commands (e.g. `sudo usermod -aG docker $USER`)
    if ($entry.post_install) {
        foreach ($postCmd in @($entry.post_install)) {
            & bash -lc $postCmd 2>&1 | Out-Host
        }
    }

    return @{ ok = $true; details = "Installed via $type" }
}

# Install-CABVSCodeExtension — meta-tool handler.
#   Iterates $Tool.extensions and calls `code --install-extension` for each.
function Install-CABVSCodeExtension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tool,
        [hashtable]$Context = @{}
    )
    if (-not (Get-Command 'code' -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; details = 'VS Code CLI (code) not on PATH; install vscode first' }
    }
    if ($Context.WhatIfMode) {
        return @{ ok = $true; details = "WhatIf: would install $($Tool.extensions.Count) extensions" }
    }
    $installed = 0
    $failed = @()
    foreach ($ext in @($Tool.extensions)) {
        Write-Host "    → code --install-extension $ext" -NoNewline
        $output = & code --install-extension $ext --force 2>&1
        Write-Host ''
        if ($LASTEXITCODE -eq 0) { $installed++ }
        else { $failed += "$ext ($($output -join '; '))" }
    }
    if ($failed.Count -gt 0) {
        return @{ ok = $false; details = "$installed installed, $($failed.Count) failed: $($failed -join '; ')" }
    }
    return @{ ok = $true; details = "$installed extensions installed" }
}

