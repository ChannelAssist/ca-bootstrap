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
    $args = if ($cmdParts.Count -gt 1) { $cmdParts[1] } else { $null }

    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        $result.status = 'fail'
        $result.details = 'Not installed (executable not on PATH).'
        return $result
    }

    try {
        $output = if ($args) {
            (& $exe $args.Split(' ') 2>&1) -join "`n"
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
    $found = $null
    foreach ($line in ($output -split "`n")) {
        if ($line -match $Tool.check.version_regex) {
            $found = $Matches[1]
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
