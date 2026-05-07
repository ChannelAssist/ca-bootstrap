#requires -Version 7.0
# tests/lib/path-norm.tests.ps1 — path-normalization invariants.
#
# These tests guard against the v1.0.2 bug class: a Windows backslash
# leaking into a context (git config value, includeIf gitdir pattern,
# YAML manifest path) where forward slashes are required.

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
    . (Join-Path $repoRoot 'steps/70-git-identity.ps1')
}

Describe 'ConvertTo-CABGitdirPattern' {
    It 'always produces forward slashes' {
        $r = ConvertTo-CABGitdirPattern -Path 'C:\Users\user\ws'
        $r | Should -Not -Match '\\'
        $r | Should -Match '^C:/Users/user/ws/$'
    }
    It 'always ends with a single trailing slash' {
        (ConvertTo-CABGitdirPattern -Path '/tmp/ws')   | Should -Be '/tmp/ws/'
        (ConvertTo-CABGitdirPattern -Path '/tmp/ws/')  | Should -Be '/tmp/ws/'
    }
}

Describe 'ConvertTo-CABAbsolutePath' {
    It 'rejects relative input' {
        { ConvertTo-CABAbsolutePath -Path 'docs/keystone' -Source 'test' } | Should -Throw '*current directory*'
    }
    It 'rejects empty input' {
        { ConvertTo-CABAbsolutePath -Path '' -Source 'test' } | Should -Throw
    }
    It 'expands ~ to the home directory' {
        $r = ConvertTo-CABAbsolutePath -Path '~/foo' -Source 'test'
        $r | Should -Match 'foo$'
        [System.IO.Path]::IsPathRooted($r) | Should -BeTrue
    }
}

Describe 'Step 70 — git identity content (regression v1.0.2)' {
    BeforeEach {
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "cab-pn-$(Get-Random)"
        [void](New-Item -ItemType Directory -Path $script:tempHome -Force)
        $script:tempWs = Join-Path $script:tempHome 'ws'
        [void](New-Item -ItemType Directory -Path $script:tempWs -Force)

        # Fake a global gitconfig path inside the test home so we never
        # touch the user's real ~/.gitconfig.
        $script:fakeGlobal = Join-Path $script:tempHome '.gitconfig'
        # Stand in for Get-CABGlobalGitconfigPath. We can't easily redirect
        # the function on every OS, so we redefine it for the test scope.
        function Get-CABGlobalGitconfigPath { $script:fakeGlobal }

        # Stub Read-Host since step 70 prompts for name/email when not in
        # unattended mode. We set Context.Unattended = true and supply
        # CA_BOOTSTRAP_GIT_NAME/EMAIL via env vars.
        $env:CA_BOOTSTRAP_GIT_NAME  = 'Test User'
        $env:CA_BOOTSTRAP_GIT_EMAIL = 'test@example.com'
        Set-CABPromptMode -Unattended $true -Answers @{ 'identity.configure' = $true }

        $script:context = @{
            RepoRoot       = (Resolve-Path "$PSScriptRoot/../..").Path
            WorkspacePath  = $script:tempWs
            Unattended     = $true
        }

        # Step 70 records a journal entry on success; it needs an active
        # session. Point the journal at a per-test temp dir so we don't
        # touch ~/.ca-bootstrap.
        $env:CA_BOOTSTRAP_STATE = $script:tempHome
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch { }
        Set-CABPromptMode -Unattended $false -Answers @{}
        Remove-Item Env:CA_BOOTSTRAP_GIT_NAME, Env:CA_BOOTSTRAP_GIT_EMAIL, Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item -Recurse -Force $script:tempHome -ErrorAction SilentlyContinue
        }
    }

    It 'global .gitconfig contains no backslash in path = or [includeIf] lines' {
        $r = Invoke-CABStep70 -Context $script:context
        $r.status | Should -BeIn @('ok','skip')
        Test-Path $script:fakeGlobal | Should -BeTrue
        $lines = Get-Content $script:fakeGlobal
        $offenders = $lines | Where-Object {
            ($_ -match '^\s*path\s*=' -or $_ -match '^\s*\[includeIf\s+"gitdir:') -and $_ -match '\\'
        }
        $offenders | Should -BeNullOrEmpty -Because '`\` in a git config value is interpreted as an escape sequence and breaks every subsequent git command (v1.0.2 bug)'
    }

    It 'workspace .gitconfig contains the expected user block with no backslash' {
        $null = Invoke-CABStep70 -Context $script:context
        $wsConfig = Join-Path $script:tempWs '.gitconfig'
        Test-Path $wsConfig | Should -BeTrue
        $content = Get-Content -Raw $wsConfig
        $content | Should -Match 'name = Test User'
        $content | Should -Match 'email = test@example\.com'
    }

    It 'global .gitconfig is parseable by git after step 70 runs' {
        $null = Invoke-CABStep70 -Context $script:context
        # We can validate parseability by running git config -f against the
        # file we just wrote; a malformed line makes git exit non-zero.
        & git config -f $script:fakeGlobal --list 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because 'git emits "bad config line N" if any value contains an unescaped backslash'
    }
}
