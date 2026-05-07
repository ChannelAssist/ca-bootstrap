#requires -Version 7.0
# tests/lib/identity-recreate.tests.ps1 — regression tests for the
# step 70 "includeIf present but workspace .gitconfig missing" path
# added in PR #17 (chore/drop-tui-restore-cli-focus). Verifies:
#   1. Test-CABStep70 returns a structured flag for the recreate case.
#   2. Invoke-CABStep70 restores the file from the most-recent
#      configure_git_identity journal entry FOR THE CURRENT
#      WORKSPACE, ignoring entries from other workspaces.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'steps/70-git-identity.ps1')
}

Describe 'Test-CABStep70 — structured recreate flag' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-state-$(Get-Random)"
        $script:tempHome  = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-home-$(Get-Random)"
        $script:tempWS    = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-ws-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempHome -Force | Out-Null
        New-Item -ItemType Directory -Path $script:tempWS   -Force | Out-Null
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch { }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        foreach ($p in @($script:tempState, $script:tempHome, $script:tempWS)) {
            if ($p -and (Test-Path $p)) {
                Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns ok status when both includeIf AND workspace .gitconfig exist' {
        $globalCfg = Join-Path $script:tempHome '.gitconfig'
        $wsCfg     = Join-Path $script:tempWS   '.gitconfig'
        $pattern   = ConvertTo-CABGitdirPattern -Path $script:tempWS
        $wsCfgFwd  = $wsCfg.Replace('\','/')
        Set-Content -Path $globalCfg -Value "[includeIf `"gitdir:$pattern`"]`n    path = $wsCfgFwd`n"
        Set-Content -Path $wsCfg     -Value "[user]`n    name = X`n    email = x@y`n"

        Mock -CommandName Get-CABGlobalGitconfigPath -MockWith { $globalCfg }
        $r = Test-CABStep70 -Context @{ WorkspacePath = $script:tempWS }
        $r.status | Should -Be 'ok'
        $r.needs_workspace_gitconfig_recreate | Should -BeNullOrEmpty
    }

    It 'returns pending + flag when includeIf exists but workspace .gitconfig is missing' {
        $globalCfg = Join-Path $script:tempHome '.gitconfig'
        $wsCfg     = Join-Path $script:tempWS   '.gitconfig'
        $pattern   = ConvertTo-CABGitdirPattern -Path $script:tempWS
        $wsCfgFwd  = $wsCfg.Replace('\','/')
        Set-Content -Path $globalCfg -Value "[includeIf `"gitdir:$pattern`"]`n    path = $wsCfgFwd`n"
        # Note: deliberately NOT writing $wsCfg.

        Mock -CommandName Get-CABGlobalGitconfigPath -MockWith { $globalCfg }
        $r = Test-CABStep70 -Context @{ WorkspacePath = $script:tempWS }
        $r.status | Should -Be 'pending'
        $r.needs_workspace_gitconfig_recreate | Should -BeTrue
    }

    It 'returns pending without recreate flag when no includeIf exists at all' {
        $globalCfg = Join-Path $script:tempHome '.gitconfig'
        Set-Content -Path $globalCfg -Value "[user]`n    name = Default`n"

        Mock -CommandName Get-CABGlobalGitconfigPath -MockWith { $globalCfg }
        $r = Test-CABStep70 -Context @{ WorkspacePath = $script:tempWS }
        $r.status | Should -Be 'pending'
        $r.needs_workspace_gitconfig_recreate | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-CABStep70 — restore from journal honors workspace scope' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-state-$(Get-Random)"
        $script:tempHome  = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-home-$(Get-Random)"
        $script:tempWS    = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-ws-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempHome -Force | Out-Null
        New-Item -ItemType Directory -Path $script:tempWS   -Force | Out-Null
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState

        # Always prepare global .gitconfig with a matching includeIf so
        # Test-CABStep70 fires the recreate path. Workspace .gitconfig
        # is intentionally absent.
        $script:globalCfg = Join-Path $script:tempHome '.gitconfig'
        $script:wsCfg     = Join-Path $script:tempWS   '.gitconfig'
        $pattern          = ConvertTo-CABGitdirPattern -Path $script:tempWS
        $wsCfgFwd         = $script:wsCfg.Replace('\','/')
        Set-Content -Path $script:globalCfg -Value "[includeIf `"gitdir:$pattern`"]`n    path = $wsCfgFwd`n"

        Mock -CommandName Get-CABGlobalGitconfigPath -MockWith { $script:globalCfg }
        Mock -CommandName Write-CABStep -MockWith { }
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch { }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        foreach ($p in @($script:tempState, $script:tempHome, $script:tempWS)) {
            if ($p -and (Test-Path $p)) {
                Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue
            }
        }
    }

    It 'restores name/email from the matching journal entry without prompting' {
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'
        Add-CABJournalEntry -Step '70-git-identity' -Action 'configure_git_identity' -Data @{
            workspace                = $script:tempWS
            global_gitconfig_path    = $script:globalCfg
            workspace_gitconfig_path = $script:wsCfg
            new_workspace_name       = 'Jane Doe'
            new_workspace_email      = 'jane@example.com'
        } | Out-Null
        Save-CABJournal

        $result = Invoke-CABStep70 -Context @{ WorkspacePath = $script:tempWS; RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path }

        $result.status | Should -Be 'ok'
        Test-Path $script:wsCfg | Should -BeTrue
        $content = Get-Content -Raw $script:wsCfg
        $content | Should -Match 'name = Jane Doe'
        $content | Should -Match 'email = jane@example.com'
    }

    It 'ignores journal entries from a DIFFERENT workspace' {
        $otherWS = Join-Path ([System.IO.Path]::GetTempPath()) "cab-id70-other-$(Get-Random)"
        New-Item -ItemType Directory -Path $otherWS -Force | Out-Null

        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version '0.0.0-test'
        # Only journal entry is for a different workspace — must NOT be
        # used to restore the current workspace's .gitconfig.
        Add-CABJournalEntry -Step '70-git-identity' -Action 'configure_git_identity' -Data @{
            workspace                = $otherWS
            global_gitconfig_path    = $script:globalCfg
            workspace_gitconfig_path = (Join-Path $otherWS '.gitconfig')
            new_workspace_name       = 'Wrong Person'
            new_workspace_email      = 'wrong@example.com'
        } | Out-Null
        Save-CABJournal

        # Force unattended so it doesn't try to Read-Host. Without a
        # matching journal entry AND no env identity, expect 'fail'.
        $ctx = @{
            WorkspacePath = $script:tempWS
            RepoRoot      = (Resolve-Path "$PSScriptRoot/../..").Path
            Unattended    = $true
        }
        # No CA_BOOTSTRAP_GIT_EMAIL — should fail validation rather
        # than silently restoring the OTHER workspace's identity.
        Remove-Item Env:CA_BOOTSTRAP_GIT_EMAIL -ErrorAction SilentlyContinue
        Remove-Item Env:CA_BOOTSTRAP_GIT_NAME  -ErrorAction SilentlyContinue
        Mock -CommandName Read-CABConfirm -MockWith { 'y' }

        $result = Invoke-CABStep70 -Context $ctx
        $result.status | Should -Be 'fail'
        # Confirm the wrong identity was NOT silently written
        Test-Path $script:wsCfg | Should -BeFalse

        Remove-Item -Recurse -Force $otherWS -ErrorAction SilentlyContinue
    }
}
