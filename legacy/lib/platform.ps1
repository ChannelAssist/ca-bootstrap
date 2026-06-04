#requires -Version 7.0
# lib/platform.ps1 — OS detection and package-manager dispatch helpers.
#
# Returns a normalized OS family string used as the lookup key in
# manifest/tools.yaml install entries.

# Get-CABOSFamily — one of:
#   'windows', 'macos', 'linux-debian', 'linux-rhel', 'linux-arch', 'linux-unknown'
function Get-CABOSFamily {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'macos' }
    if ($IsLinux) {
        if (Test-Path '/etc/os-release') {
            $osRelease = Get-Content '/etc/os-release' -Raw
            if ($osRelease -match '(?m)^ID=(\w+)') {
                $id = $Matches[1].Trim('"')
                switch -Wildcard ($id) {
                    'debian'    { return 'linux-debian' }
                    'ubuntu'    { return 'linux-debian' }
                    'rhel'      { return 'linux-rhel' }
                    'fedora'    { return 'linux-rhel' }
                    'centos'    { return 'linux-rhel' }
                    'rocky'     { return 'linux-rhel' }
                    'almalinux' { return 'linux-rhel' }
                    'arch'      { return 'linux-arch' }
                    'manjaro'   { return 'linux-arch' }
                }
            }
            if ($osRelease -match '(?m)^ID_LIKE=(.+)') {
                $idLike = $Matches[1].Trim('"').ToLower()
                if ($idLike -match 'debian|ubuntu') { return 'linux-debian' }
                if ($idLike -match 'rhel|fedora')   { return 'linux-rhel' }
                if ($idLike -match 'arch')          { return 'linux-arch' }
            }
        }
        return 'linux-unknown'
    }
    return 'unknown'
}

# Get-CABInstallEntry — find the right install spec for a tool on this OS.
#   Looks up tool.install[<os>], falling back to tool.install['any'] if
#   present. Returns $null if neither exists. The shape it returns matches
#   manifest/tools.yaml install entries (a hashtable with type, id, etc.).
function Get-CABInstallEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Tool,
        [string]$OSFamily
    )
    if (-not $OSFamily) { $OSFamily = Get-CABOSFamily }
    if (-not $Tool.install) { return $null }

    # Linux entries are nested under linux: { debian: ..., rhel: ... } in
    # the manifest; Windows/macOS are flat. Handle both shapes.
    if ($Tool.install.ContainsKey($OSFamily)) {
        return $Tool.install[$OSFamily]
    }
    if ($OSFamily -like 'linux-*' -and $Tool.install.ContainsKey('linux')) {
        $sub = $OSFamily -replace '^linux-', ''
        if ($Tool.install['linux'].ContainsKey($sub)) {
            return $Tool.install['linux'][$sub]
        }
        if ($Tool.install['linux'].ContainsKey('any')) {
            return $Tool.install['linux']['any']
        }
    }
    if ($Tool.install.ContainsKey('any')) {
        return $Tool.install['any']
    }
    return $null
}
