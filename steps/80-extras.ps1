#requires -Version 7.0
# steps/80-extras.ps1 — optional finishing touches.
#
# Four offers (each independently confirmable):
#   1. VS Code multi-root workspace file at <workspace>/ChannelAssist.code-workspace
#   2. ca-claude-plugin activation pointer (creates a symlink under
#      ~/.claude/plugins/ pointing at the cloned repo, if present)
#   3. ca-copilot-plugin info — verify the repo is cloned and explain how the
#      custom agents and prompts activate in consumer repos via the sync flow
#      (Copilot resolves agents per-repo from .github/agents/ and per-repo
#      prompts from .github/prompts/, so there is no per-developer "install"
#      symlink — the bootstrap's role is to clone the repo and surface usage)
#   4. WSL2 + Ubuntu 22.04 install (Windows-only)
#
# Claude Code itself is handled by step 20 (it's in manifest/tools.yaml).
# GitHub Copilot (the VS Code extension pair) is also in step 20 via
# manifest/tools.yaml's vscode-extensions.
# This step is only for things downstream of "I have a working dev env."

function Get-CABClaudePluginsDir {
    if ($IsWindows) { return Join-Path $env:USERPROFILE '.claude\plugins' }
    return Join-Path $HOME '.claude/plugins'
}

# Walk the workspace and collect everything that looks like a cloned repo.
# Group list is derived from manifest/folders.yaml — adding a top-level
# group there flows through here automatically. (Note: a group declared
# only in manifest/repos.yaml without a matching folders.yaml entry is
# NOT discovered by this function; the convention is that every cloning
# group has its own workspace folder declared in folders.yaml.) Falls
# back to a hardcoded set if the manifest can't be read (e.g. unit
# tests that exercise step 80 without RepoRoot wired in).
function Get-CABClonedReposFromWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [string]$RepoRoot
    )
    $repos = New-Object System.Collections.Generic.List[hashtable]
    $groups = $null
    if ($RepoRoot) {
        try {
            $foldersManifest = Read-CABManifest -Path (Join-Path $RepoRoot 'manifest/folders.yaml')
            $groups = @($foldersManifest.folders | ForEach-Object { [string]$_.path })
        } catch {
            Write-Verbose "Could not read folders.yaml: $($_.Exception.Message)"
        }
    }
    if (-not $groups) {
        $groups = @('docs','ca-platform','cm-product','ado-legacy','learning','experiments')
    }
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
    @{ status = 'pending'; details = 'Four optional extras available.' }
}

function Invoke-CABStep80 {
    [CmdletBinding()]
    param([hashtable]$Context)

    Write-CABStep -Number ($Context.StepOrdinal ?? 8) -Total $Context.TotalSteps -Title 'Optional extras'

    if (-not $Context.WorkspacePath) {
        return @{ status = 'fail'; details = 'Workspace not set.' }
    }

    $actions = @()

    # ---------- 1. VS Code multi-root workspace file ----------
    $workspaceFile = Join-Path $Context.WorkspacePath 'ChannelAssist.code-workspace'
    $existsHint = if (Test-Path $workspaceFile) { ' (already exists; will overwrite)' } else { '' }
    $createWorkspaceFile = Read-CABConfirm `
        -Question "Create VS Code multi-root workspace file at ChannelAssist.code-workspace$($existsHint)?" `
        -Default $true `
        -AnswerKey 'extras.vscode_workspace_file'
    if (Test-CABQuit $createWorkspaceFile) {
        return @{ status = 'quit'; details = 'User quit during extras step.' }
    }
    if (Test-CABYes $createWorkspaceFile) {
        $repos = Get-CABClonedReposFromWorkspace -WorkspacePath $Context.WorkspacePath -RepoRoot $Context.RepoRoot
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
        if (Test-CABQuit $linkPlugin) {
            return @{ status = 'quit'; details = 'User quit during extras step.' }
        }
        if (Test-CABYes $linkPlugin) {
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

    # ---------- 3. ca-copilot-plugin info (clone + usage explainer) ----------
    $copilotPluginPath = Join-Path $Context.WorkspacePath 'ca-platform/ca-copilot-plugin'
    if (Test-Path $copilotPluginPath) {
        $showCopilot = Read-CABConfirm `
            -Question 'Show ca-copilot-plugin usage notes (how custom agents/prompts activate in your repos)?' `
            -Default $false `
            -AnswerKey 'extras.ca_copilot_plugin'
        if (Test-CABQuit $showCopilot) {
            return @{ status = 'quit'; details = 'User quit during extras step.' }
        }
        if (Test-CABYes $showCopilot) {
            Write-CABStatus -Status info -Message 'ca-copilot-plugin cloned at:'
            Write-CABColor DarkGray "      $copilotPluginPath"
            Write-CABColor DarkGray ''
            Write-CABColor DarkGray '    Custom agents and prompt files in this repo become available in Copilot'
            Write-CABColor DarkGray '    Chat when they are synced into a consumer repo''s .github/agents/ and'
            Write-CABColor DarkGray '    .github/prompts/ directories. Sync flow:'
            Write-CABColor DarkGray ''
            Write-CABColor DarkGray '      cd cm-product/cm-platform-infra'
            Write-CABColor DarkGray '      make agents-sync REPO=ChannelAssist/<your-repo>'
            Write-CABColor DarkGray ''
            Write-CABColor DarkGray '    Once the resulting sync PR merges in <your-repo>, opening it in VS Code'
            Write-CABColor DarkGray '    with GitHub Copilot Chat enabled exposes the agents (@<name>) and the'
            Write-CABColor DarkGray '    prompts (/<name>). See ca-copilot-plugin/README.md for the full reference.'
            Add-CABJournalEntry -Step '80-extras' -Action 'show_ca_copilot_plugin_usage' -Reversible $false -Data @{
                repo_path = $copilotPluginPath
            } | Out-Null
            $actions += 'ca-copilot-plugin'
        } else {
            Write-CABStatus -Status skip -Message 'ca-copilot-plugin usage notes skipped.'
        }
    } else {
        Write-CABStatus -Status info -Message 'ca-copilot-plugin not cloned (skip its repo group to enable).'
    }

    # ---------- 4. WSL2 + Ubuntu 22.04 (Windows-only) ----------
    if ($IsWindows) {
        # Pre-compute the wsl-already-has-Ubuntu check on its own line.
        # Inlining `2>$null` inside the if-condition triggered
        # PSPossibleIncorrectUsageOfRedirectionOperator (PSSA mis-parses
        # the redirect across the backtick continuation).
        $wslHasUbuntu = $false
        if (-not $Context.WhatIfMode -and (Get-Command wsl -ErrorAction SilentlyContinue)) {
            $wslList = (& wsl -l 2>$null | Out-String)
            $wslHasUbuntu = $wslList -match 'Ubuntu'
        }
        if ($wslHasUbuntu) {
            Write-CABStatus -Status skip -Message 'WSL with Ubuntu already installed.'
        } else {
            Write-CABColor DarkGray '    ⓘ Will install with --no-launch so the wizard does not block. After'
            Write-CABColor DarkGray '      reboot, run `wsl -d Ubuntu-22.04` from a new terminal to create your'
            Write-CABColor DarkGray '      Linux username + password.'
            $installWsl = Read-CABConfirm `
                -Question 'Install WSL2 + Ubuntu 22.04 (requires reboot)?' `
                -Default $false `
                -AnswerKey 'extras.wsl_ubuntu_2204'
            if (Test-CABQuit $installWsl) {
                return @{ status = 'quit'; details = 'User quit during extras step.' }
            }
            if (Test-CABYes $installWsl) {
                if ($Context.WhatIfMode) {
                    Write-CABStatus -Status info -Message 'WhatIf: would run `wsl --install --no-launch -d Ubuntu-22.04`'
                } else {
                    # --no-launch is critical: without it, `wsl --install` drops the
                    # user into the new Ubuntu shell after first-run setup, which
                    # blocks ca-bootstrap.ps1 because Windows treats the bash session
                    # as a child of our PowerShell process. With --no-launch the
                    # distro is installed but not started; the user runs it manually
                    # later (which is when the username/password prompt appears).
                    & wsl --install --no-launch -d Ubuntu-22.04
                    if ($LASTEXITCODE -eq 0) {
                        Write-CABStatus -Status ok -Message 'WSL2 + Ubuntu 22.04 installed. Reboot, then run `wsl -d Ubuntu-22.04` to create your Linux user.'
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
    @{ status = 'noop'; details = 'Reversed by undo per journal entry (workspace file deletion, plugin unlink, copilot info no-op, WSL refused).' }
}
