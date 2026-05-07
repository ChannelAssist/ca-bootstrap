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
    # Resolve the user's profile directory robustly. On Windows, $env:USERPROFILE
    # is normally `C:\Users\<name>` but can be missing or wrong in unusual
    # environments (Git Bash launching pwsh, custom shells, CI sandboxes). Fall
    # back through several candidates and validate that the result is absolute.
    $candidates = if ($IsWindows) {
        @($env:USERPROFILE, $HOME, $env:HOMEDRIVE + $env:HOMEPATH) | Where-Object { $_ }
    } else {
        @($HOME, $env:HOME) | Where-Object { $_ }
    }
    $profileDir = $candidates | Where-Object {
        $_ -and [System.IO.Path]::IsPathRooted($_) -and (Test-Path $_)
    } | Select-Object -First 1
    if (-not $profileDir) {
        throw "Could not resolve a user profile directory. Tried: $($candidates -join ', '). Set CA_BOOTSTRAP_WORKSPACE to an absolute path and re-run."
    }
    # Prefer Documents/ when it exists (the typical desktop layout). On
    # headless / minimal Linux installs the XDG userdirs may not be
    # configured and ~/Documents/ won't exist — silently creating one
    # there would be surprising. Fall back to <profile>/Projects/ in
    # that case so the workspace lands somewhere the user expects on a
    # bare box.
    $docsDir = Join-Path $profileDir 'Documents'
    $hasDocs = Test-Path $docsDir -PathType Container
    if ($hasDocs) {
        $sub = if ($IsWindows) { 'Documents\Projects\ChannelAssistDev' } else { 'Documents/Projects/ChannelAssistDev' }
    } else {
        $sub = if ($IsWindows) { 'Projects\ChannelAssistDev' } else { 'Projects/ChannelAssistDev' }
    }
    return [System.IO.Path]::GetFullPath((Join-Path $profileDir $sub))
}

# ConvertTo-CABAbsolutePath — defensive normalization. Refuses to return a
# relative path: every consumer of WorkspacePath assumes absolute, so a bug
# in path resolution becomes "clones land in cwd." Throw rather than guess.
function ConvertTo-CABAbsolutePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Source = 'workspace')
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Source path is empty."
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Replace('~', $HOME))
    # Reject relative input *before* GetFullPath has a chance to silently
    # resolve it against cwd (which would defeat the whole point — a user-
    # supplied "docs/foo" would become "<cwd>/docs/foo" and we'd happily
    # create files in their current directory).
    if (-not [System.IO.Path]::IsPathRooted($expanded)) {
        throw "$Source path '$Path' is not absolute. Refusing to proceed (would create files in your current directory)."
    }
    $absolute = try { [System.IO.Path]::GetFullPath($expanded) } catch {
        throw "$Source path '$Path' could not be resolved: $($_.Exception.Message)"
    }
    return $absolute
}

function Invoke-CABStep40 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number ($Context.StepOrdinal ?? 4) -Total $Context.TotalSteps -Title 'Workspace location'

    # Resolve the default workspace path (absolute, guaranteed).
    try {
        $default = if ($env:CA_BOOTSTRAP_WORKSPACE) {
            ConvertTo-CABAbsolutePath -Path $env:CA_BOOTSTRAP_WORKSPACE -Source 'CA_BOOTSTRAP_WORKSPACE'
        } else {
            Get-CABDefaultWorkspacePath
        }
    } catch {
        return @{ status = 'fail'; details = $_.Exception.Message }
    }

    # Print the resolved path on its own line above the prompt. A long
    # path inlined into the question (the v1.4.x TUI-era shape) makes a
    # 90+ char line that wraps mid-path on standard 80-col terminals;
    # users miss the wrapped portion. Two lines reads cleanly: path
    # first as a labeled line, then a short y/n.
    Write-Host ''
    Write-Host "  Default location: $default"
    Write-Host ''

    $useDefault = Read-CABConfirm `
        -Question 'Use this default?' `
        -Default $true `
        -AnswerKey 'workspace.use_default'
    if (Test-CABQuit $useDefault) {
        return @{ status = 'quit'; details = 'User quit at workspace step.' }
    }

    if (Test-CABNo $useDefault) {
        Write-Host '  Custom path (must be absolute):'
        Write-Host "  > " -NoNewline
        $custom = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($custom)) {
            return @{ status = 'fail'; details = 'No path provided.' }
        }
        try {
            $workspace = ConvertTo-CABAbsolutePath -Path $custom -Source 'custom workspace'
        } catch {
            return @{ status = 'fail'; details = $_.Exception.Message }
        }
    } else {
        $workspace = $default
    }

    # Hard guarantee: never proceed with a relative path. If we somehow have
    # one despite the helper, fail loudly rather than create folders + clone
    # in the user's cwd.
    if (-not [System.IO.Path]::IsPathRooted($workspace)) {
        return @{ status = 'fail'; details = "Workspace path '$workspace' is not absolute. Refusing to proceed." }
    }

    Write-Host ''
    Write-CABColor White "  Workspace will be: $workspace"

    # Verify writable.
    $parent = Split-Path -Parent $workspace
    if (-not (Test-Path $parent)) {
        try { [void](New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop) }
        catch { return @{ status = 'fail'; details = "Cannot create parent directory '$parent': $($_.Exception.Message)" } }
    }

    if (-not (Test-Path $workspace)) {
        try { [void](New-Item -ItemType Directory -Path $workspace -Force -ErrorAction Stop) }
        catch { return @{ status = 'fail'; details = "Cannot create workspace '$workspace': $($_.Exception.Message)" } }
        # Confirm it actually got created — a successful New-Item that doesn't
        # produce a directory means something is very wrong with the host.
        if (-not (Test-Path $workspace -PathType Container)) {
            return @{ status = 'fail'; details = "Workspace creation reported success but '$workspace' does not exist as a directory." }
        }
        Add-CABJournalEntry -Step '40-workspace' -Action 'create_folder' -Data @{ path = $workspace; is_workspace_root = $true } | Out-Null
        $created = $true
    } else {
        $created = $false
    }

    $Context.WorkspacePath = $workspace
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
