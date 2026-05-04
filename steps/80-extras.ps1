#requires -Version 7.0
# steps/80-extras.ps1 — optional finishing touches.
#
# Three offers (each independently confirmable):
#   1. VS Code multi-root workspace file at <workspace>/ChannelAssist.code-workspace
#   2. ca-claude-plugin activation pointer (creates a symlink under
#      ~/.claude/plugins/ pointing at the cloned repo, if present)
#   3. WSL2 + Ubuntu 22.04 install (Windows-only)
#
# Claude Code itself is handled by step 20 (it's in manifest/tools.yaml).
# This step is only for things downstream of "I have a working dev env."

function Get-CABClaudePluginsDir {
    if ($IsWindows) { return Join-Path $env:USERPROFILE '.claude\plugins' }
    return Join-Path $HOME '.claude/plugins'
}

# Walk the workspace and collect everything that looks like a cloned repo.
function Get-CABClonedReposFromWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkspacePath)
    $repos = New-Object System.Collections.Generic.List[hashtable]
    $groups = @('docs','ca-platform','cm-product','ado-legacy')
    foreach ($group in $groups) {
        $groupDir = Join-Path $WorkspacePath $group
        if (-not (Test-Path $groupDir)) { continue }
        Get-ChildItem -Path $groupDir -Directory | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName '.git')) {
                $repos.Add(@{
                    name = $_.Name
                    path = Join-Path $group $_.Name
                })
            }
        }
    }
    return $repos
}

function Test-CABStep80 {
    [CmdletBinding()]
    param([hashtable]$Context)
    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set.' }
    }
    @{ status = 'pending'; details = 'Three optional extras available.' }
}

function Invoke-CABStep80 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number 8 -Total $Context.TotalSteps -Title 'Optional extras'

    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set.' }
    }

    $actions = @()

    # ---------- 1. VS Code multi-root workspace file ----------
    $workspaceFile = Join-Path $Context.WorkspacePath 'ChannelAssist.code-workspace'
    $existsHint = if (Test-Path $workspaceFile) { ' (already exists; will overwrite)' } else { '' }
    $createWorkspaceFile = Read-CABConfirm `
        -Question "Create VS Code multi-root workspace file at ChannelAssist.code-workspace$existsHint?" `
        -Default $true `
        -AnswerKey 'extras.vscode_workspace_file'
    if ($createWorkspaceFile -is [string] -and $createWorkspaceFile -eq 'quit') {
        return @{ status = 'quit'; details = 'User quit during extras step.' }
    }
    if ($createWorkspaceFile -is [bool] -and $createWorkspaceFile) {
        $repos = Get-CABClonedReposFromWorkspace -WorkspacePath $Context.WorkspacePath
        if ($repos.Count -eq 0) {
            Write-CABStatus -Status warn -Message 'No cloned repos detected — skipping workspace file.'
        } else {
            $folders = $repos | ForEach-Object {
                @{ name = $_.name; path = $_.path -replace '\\','/' }
            }
            $payload = [ordered]@{
                folders  = $folders
                settings = [ordered]@{
                    'files.exclude'  = [ordered]@{
                        '**/node_modules' = $true
                        '**/bin'          = $true
                        '**/obj'          = $true
                    }
                    'search.exclude' = [ordered]@{
                        '**/node_modules' = $true
                        '**/bin'          = $true
                        '**/obj'          = $true
                        '**/wiki'         = $true
                    }
                }
            }
            if ($Context.WhatIfMode) {
                Write-CABStatus -Status info -Message "WhatIf: would write $workspaceFile listing $($folders.Count) folders"
            } else {
                $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $workspaceFile
                Write-CABStatus -Status ok -Message "Wrote $workspaceFile ($($folders.Count) folders)"
                Add-CABJournalEntry -Step '80-extras' -Action 'create_workspace_file' -Data @{
                    path = $workspaceFile
                } | Out-Null
                $actions += 'workspace-file'
            }
        }
    } else {
        Write-CABStatus -Status skip -Message 'VS Code workspace file skipped.'
    }

    # ---------- 2. ca-claude-plugin activation pointer ----------
    $pluginRepoPath = Join-Path $Context.WorkspacePath 'ca-platform/ca-claude-plugin'
    if (Test-Path $pluginRepoPath) {
        $pluginsDir   = Get-CABClaudePluginsDir
        $linkPath     = Join-Path $pluginsDir 'ca-claude-plugin'
        $alreadyLinked = (Test-Path $linkPath)
        $promptText = if ($alreadyLinked) {
            'ca-claude-plugin link already present at ~/.claude/plugins/ca-claude-plugin. Refresh?'
        } else {
            'Link ca-claude-plugin into ~/.claude/plugins so Claude Code can load it?'
        }
        $linkPlugin = Read-CABConfirm `
            -Question $promptText `
            -Default $false `
            -AnswerKey 'extras.ca_claude_plugin'
        if ($linkPlugin -is [string] -and $linkPlugin -eq 'quit') {
            return @{ status = 'quit'; details = 'User quit during extras step.' }
        }
        if ($linkPlugin -is [bool] -and $linkPlugin) {
            if ($Context.WhatIfMode) {
                Write-CABStatus -Status info -Message "WhatIf: would symlink $linkPath → $pluginRepoPath"
            } else {
                if (-not (Test-Path $pluginsDir)) { [void](New-Item -ItemType Directory -Path $pluginsDir -Force) }
                if ($alreadyLinked) { Remove-Item -Path $linkPath -Force -ErrorAction SilentlyContinue }
                try {
                    if ($IsWindows) {
                        # Windows symlinks need elevated rights or Developer Mode; junctions don't.
                        & cmd /c mklink /J "$linkPath" "$pluginRepoPath" | Out-Null
                    } else {
                        New-Item -ItemType SymbolicLink -Path $linkPath -Target $pluginRepoPath | Out-Null
                    }
                    Write-CABStatus -Status ok -Message "Linked: $linkPath → $pluginRepoPath"
                    Write-CABColor DarkGray "      ⓘ Restart Claude Code or run its plugin-reload command to pick it up."
                    Add-CABJournalEntry -Step '80-extras' -Action 'install_ca_claude_plugin' -Data @{
                        link_path        = $linkPath
                        target_repo_path = $pluginRepoPath
                    } | Out-Null
                    $actions += 'ca-claude-plugin'
                } catch {
                    Write-CABStatus -Status fail -Message "Plugin link failed: $($_.Exception.Message)"
                }
            }
        } else {
            Write-CABStatus -Status skip -Message 'ca-claude-plugin link skipped.'
        }
    } else {
        Write-CABStatus -Status info -Message 'ca-claude-plugin not cloned (skip its repo group to enable).'
    }

    # ---------- 3. WSL2 + Ubuntu 22.04 (Windows-only) ----------
    if ($IsWindows) {
        if (-not $Context.WhatIfMode -and (Get-Command wsl -ErrorAction SilentlyContinue) `
            -and ((& wsl -l 2>$null | Out-String) -match 'Ubuntu')) {
            Write-CABStatus -Status skip -Message 'WSL with Ubuntu already installed.'
        } else {
            $installWsl = Read-CABConfirm `
                -Question 'Install WSL2 + Ubuntu 22.04 (requires reboot)?' `
                -Default $false `
                -AnswerKey 'extras.wsl_ubuntu_2204'
            if ($installWsl -is [string] -and $installWsl -eq 'quit') {
                return @{ status = 'quit'; details = 'User quit during extras step.' }
            }
            if ($installWsl -is [bool] -and $installWsl) {
                if ($Context.WhatIfMode) {
                    Write-CABStatus -Status info -Message 'WhatIf: would run `wsl --install -d Ubuntu-22.04`'
                } else {
                    & wsl --install -d Ubuntu-22.04
                    if ($LASTEXITCODE -eq 0) {
                        Write-CABStatus -Status ok -Message 'WSL2 + Ubuntu 22.04 installation triggered. A reboot is required.'
                        Add-CABJournalEntry -Step '80-extras' -Action 'install_wsl' -Reversible $false -Data @{
                            distro = 'Ubuntu-22.04'
                        } | Out-Null
                        $actions += 'wsl'
                    } else {
                        Write-CABStatus -Status fail -Message "wsl --install exited $LASTEXITCODE"
                    }
                }
            } else {
                Write-CABStatus -Status skip -Message 'WSL install skipped.'
            }
        }
    }

    if ($actions.Count -eq 0) {
        return @{ status = 'skip'; details = 'No extras applied.' }
    }
    return @{ status = 'ok'; details = "Applied: $($actions -join ', ')" }
}

function Undo-CABStep80 {
    @{ status = 'noop'; details = 'Reversed by undo per journal entry (workspace file deletion, plugin unlink, WSL refused).' }
}
