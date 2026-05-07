#requires -Version 7.0
# lib/yaml.ps1 — YAML parsing for manifests.
#
# Wraps the powershell-yaml community module. Installs it on demand if
# missing (CurrentUser scope, no admin needed).

function Initialize-CABYaml {
    [CmdletBinding()]
    param()
    if (Get-Module -ListAvailable -Name powershell-yaml) { return }
    Write-CABColor Yellow '  Installing powershell-yaml module (one-time, current user)...'
    try {
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default -ErrorAction SilentlyContinue
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-CABColor Green '  ✓ powershell-yaml installed.'
    } catch {
        throw "Failed to install powershell-yaml: $($_.Exception.Message)"
    }
}

function Read-CABManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Manifest not found: $Path" }
    Initialize-CABYaml
    Import-Module powershell-yaml -DisableNameChecking
    $raw = Get-Content -Raw -Path $Path
    return ConvertFrom-Yaml $raw
}
