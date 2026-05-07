#requires -Version 7.0
# lib/answers.ps1 — flatten the structured answers.yaml into the flat
# AnswerKey form the Read-CABConfirm / Read-CABChoice helpers consume.
#
# The shape of the YAML is documented in manifest/answers.example.yaml.

function Read-CABAnswersFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Answers file not found: $Path" }
    Initialize-CABYaml
    Import-Module powershell-yaml -DisableNameChecking
    $raw = Get-Content -Raw -Path $Path
    return ConvertFrom-Yaml $raw
}

# Convert-CABAnswersToFlat — translate the structured answers hashtable
# into the flat AnswerKey table the prompt helpers look up.
#
# Returns @{ 'welcome.continue' = $true; 'workspace.use_default' = $true; ... }
function Convert-CABAnswersToFlat {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Answers)

    $flat = @{}

    # Welcome / consent — always proceed in unattended mode.
    $flat['welcome.continue'] = $true

    # Workspace
    if ($Answers.workspace.path) {
        # Setting the env var so step 40 picks it up as the default.
        $env:CA_BOOTSTRAP_WORKSPACE = $Answers.workspace.path
    }
    $flat['workspace.use_default'] = $true

    # Folders — always create (skip individuals isn't supported in v1).
    $flat['folders.continue'] = $true

    # Prerequisites
    if ($Answers.prerequisites) {
        if ($Answers.prerequisites.install_missing) {
            $flat['prereqs.install_choice'] = 'Y'
        } else {
            $flat['prereqs.install_choice'] = 'n'
        }
        if ($Answers.prerequisites.selections) {
            foreach ($k in $Answers.prerequisites.selections.Keys) {
                $v = $Answers.prerequisites.selections[$k]
                $flat["prereqs.install.$k"] = ($v -eq 'install')
            }
        }
    }

    # GitHub auth
    if ($Answers.github_auth) {
        $flat['gh-auth.login'] = [bool]$Answers.github_auth.required
    }

    # Repo cloning
    if ($Answers.clone -and $Answers.clone.groups) {
        foreach ($groupName in $Answers.clone.groups.Keys) {
            $val = $Answers.clone.groups[$groupName]
            $key = switch ($val) {
                'all'  { 'Y' }
                'none' { 'n' }
                'skip' { 'n' }
                default { 'Y' }
            }
            $flat["repos.group.$groupName"] = $key
        }
    }
    if ($Answers.clone -and $Answers.clone.exclude) {
        foreach ($slug in @($Answers.clone.exclude)) {
            $flat["repos.repo.$slug"] = $false
        }
    }

    # Git identity
    if ($Answers.git_identity) {
        $flat['identity.configure'] = [bool]$Answers.git_identity.configure
        # Prompt-injected name/email come via env vars to avoid Read-Host reads.
        if ($Answers.git_identity.name)  { $env:CA_BOOTSTRAP_GIT_NAME  = [string]$Answers.git_identity.name }
        if ($Answers.git_identity.email) { $env:CA_BOOTSTRAP_GIT_EMAIL = [string]$Answers.git_identity.email }
    }

    # Extras
    if ($Answers.extras) {
        if ($null -ne $Answers.extras.vscode_workspace_file) {
            $flat['extras.vscode_workspace_file'] = [bool]$Answers.extras.vscode_workspace_file
        }
        if ($null -ne $Answers.extras.ca_claude_plugin) {
            $flat['extras.ca_claude_plugin'] = [bool]$Answers.extras.ca_claude_plugin
        }
        if ($null -ne $Answers.extras.ca_copilot_plugin) {
            $flat['extras.ca_copilot_plugin'] = [bool]$Answers.extras.ca_copilot_plugin
        }
        if ($null -ne $Answers.extras.wsl_ubuntu_2204) {
            $flat['extras.wsl_ubuntu_2204'] = [bool]$Answers.extras.wsl_ubuntu_2204
        }
    }

    # Undo
    $flat['undo.proceed'] = $true

    return $flat
}
