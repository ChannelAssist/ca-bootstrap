#requires -Version 7.0
# tests/regression/v1.0.3-workspace-relative.tests.ps1
#
# Bug fixed: e83e9cc — workspace path could leak through as relative,
# causing the wizard to create folders + clone repos under the user's
# current directory. The user reported this on Windows; root cause was
# either an empty $env:USERPROFILE or a Get-CABDefaultWorkspacePath
# code path that produced a non-rooted result.
#
# Property under test: every code path that produces $Context.WorkspacePath
# must produce an absolute path or fail with a clear "refusing to proceed"
# message. Steps 50 and 60 must also refuse to mutate disk if the path is
# somehow not rooted.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'lib/git-ops.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
    . (Join-Path $repoRoot 'steps/40-workspace.ps1')
    . (Join-Path $repoRoot 'steps/50-folders.ps1')
    . (Join-Path $repoRoot 'steps/60-repos.ps1')
}

Describe 'Step 40 — workspace path resolution (regression v1.0.3)' {
    It 'rejects a relative path supplied via $env:CA_BOOTSTRAP_WORKSPACE' {
        $env:CA_BOOTSTRAP_WORKSPACE = 'relative/dir'
        Set-CABPromptMode -Unattended $true -Answers @{ 'workspace.use_default' = $true }
        try {
            $ctx = @{ TotalSteps = 8 }
            $r = Invoke-CABStep40 -Context $ctx
            $r.status | Should -Be 'fail'
            $r.details | Should -Match 'not absolute|Refusing to proceed'
            $ctx.WorkspacePath | Should -BeNullOrEmpty
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_WORKSPACE -ErrorAction SilentlyContinue
            Set-CABPromptMode -Unattended $false -Answers @{}
        }
    }

    It 'rejects relative custom path' {
        $env:CA_BOOTSTRAP_WORKSPACE = '/tmp/cab-rel-test/ChannelAssistDev'
        # User says "no, custom" then supplies a relative path. The custom
        # branch's read-host can't easily be mocked, so we drive the failure
        # via the env var path which uses the same ConvertTo-CABAbsolutePath.
        try {
            { ConvertTo-CABAbsolutePath -Path 'foo/bar' -Source 'workspace' } | Should -Throw '*not absolute*'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_WORKSPACE -ErrorAction SilentlyContinue
        }
    }

    It 'Get-CABDefaultWorkspacePath returns a rooted path' {
        $r = Get-CABDefaultWorkspacePath
        [System.IO.Path]::IsPathRooted($r) | Should -BeTrue
    }
}

Describe 'Step 50 / 60 — refuse to mutate disk on a relative WorkspacePath' {
    It 'step 50 returns fail when WorkspacePath is relative' {
        $r = Invoke-CABStep50 -Context @{
            RepoRoot      = (Resolve-Path "$PSScriptRoot/../..").Path
            WorkspacePath = './bogus'
            TotalSteps    = 8
        }
        $r.status | Should -Be 'fail'
        $r.details | Should -Match 'not absolute'
    }

    It 'step 60 returns fail when WorkspacePath is relative (no clone is attempted)' {
        # Set up just enough to get past the Test-CABCommandAvailable +
        # Test-CABGhAuth checks; we use the test-mode seam.
        $r = Invoke-CABStep60 -Context @{
            RepoRoot      = (Resolve-Path "$PSScriptRoot/../..").Path
            WorkspacePath = './bogus'
            TotalSteps    = 8
            TestMode      = $true
            TestGhUser    = 'fake-user'
        }
        $r.status | Should -Be 'fail'
        $r.details | Should -Match 'not absolute|Refusing to clone'
    }

    It 'step 60 returns fail when WorkspacePath is empty string' {
        $r = Invoke-CABStep60 -Context @{
            RepoRoot      = (Resolve-Path "$PSScriptRoot/../..").Path
            WorkspacePath = ''
            TotalSteps    = 8
            TestMode      = $true
            TestGhUser    = 'fake-user'
        }
        $r.status | Should -Be 'fail'
    }
}
