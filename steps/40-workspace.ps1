#requires -Version 7.0
# steps/40-workspace.ps1 — pick the workspace root path.

function Test-CABStep40 {
    [CmdletBinding()]
    param([hashtable]$Context)
    $path = if ($env:CA_BOOTSTRAP_WORKSPACE) {
        $env:CA_BOOTSTRAP_WORKSPACE
    } else {
        Get-CABDefaultWorkspacePath
    }
    if (Test-Path $path) {
        return @{ status = 'ok'; details = "Workspace exists at $path"; workspace = $path }
    }
    return @{ status = 'pending'; details = "Workspace will be created at $path"; workspace = $path }
}

function Get-CABDefaultWorkspacePath {
    if ($IsWindows) {
        return Join-Path $env:USERPROFILE 'Documents\Projects\Work\ChannelAssist\ChannelAssistDev'
    }
    return Join-Path $HOME 'Documents/Projects/Work/ChannelAssist/ChannelAssistDev'
}

function Invoke-CABStep40 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number 4 -Total $Context.TotalSteps -Title 'Workspace location'

    $default = if ($env:CA_BOOTSTRAP_WORKSPACE) { $env:CA_BOOTSTRAP_WORKSPACE } else { Get-CABDefaultWorkspacePath }
    Write-Host "  Default location: $default"
    Write-Host ''

    $useDefault = Read-CABConfirm -Question 'Use this default?' -Default $true -AnswerKey 'workspace.use_default'
    if ($useDefault -is [string] -and $useDefault -eq 'quit') {
        return @{ status = 'quit'; details = 'User quit at workspace step.' }
    }

    if ($useDefault -is [bool] -and -not $useDefault) {
        Write-Host '  Custom path:'
        Write-Host "  > " -NoNewline
        $custom = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($custom)) {
            return @{ status = 'fail'; details = 'No path provided.' }
        }
        # Expand ~/ and environment variables
        $custom = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($custom.Replace('~', $HOME)))
        $workspace = $custom
    } else {
        $workspace = $default
    }

    # Verify writable.
    $parent = Split-Path -Parent $workspace
    if (-not (Test-Path $parent)) {
        try { [void](New-Item -ItemType Directory -Path $parent -Force) }
        catch { return @{ status = 'fail'; details = "Cannot create parent directory: $($_.Exception.Message)" } }
    }

    if (-not (Test-Path $workspace)) {
        try { [void](New-Item -ItemType Directory -Path $workspace -Force) }
        catch { return @{ status = 'fail'; details = "Cannot create workspace: $($_.Exception.Message)" } }
        $action = Add-CABJournalEntry -Step '40-workspace' -Action 'create_folder' -Data @{ path = $workspace; is_workspace_root = $true }
        $created = $true
    } else {
        $created = $false
    }

    $Context.WorkspacePath = $workspace
    Write-Host ''
    if ($created) {
        return @{ status = 'ok'; details = "Created workspace at $workspace" }
    }
    return @{ status = 'skip'; details = "Using existing workspace at $workspace" }
}

function Undo-CABStep40 {
    # Reversal handled by the journal walker in phase 10 — removes the
    # workspace dir if empty.
    @{ status = 'noop'; details = 'Reversal handled by undo command.' }
}
