#requires -Version 7.0
# tests/lib/encoding-and-paths.tests.ps1 — v1.2.0 hardening:
#   * Path-with-spaces / non-ASCII workspace round-trips
#   * UTF-8 encoding for git config writes (catches windows-1252 mangling)

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

Describe 'Workspace path with spaces and non-ASCII chars' {
    It 'ConvertTo-CABAbsolutePath accepts a path with spaces' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cab path $(Get-Random)"
        $r = ConvertTo-CABAbsolutePath -Path $tmp -Source 'test'
        [System.IO.Path]::IsPathRooted($r) | Should -BeTrue
        $r | Should -Match '\s'
    }
    It 'ConvertTo-CABAbsolutePath accepts a path with non-ASCII characters' -Skip:($IsWindows) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cab-unicode-Émilie-Müller-$(Get-Random)"
        $r = ConvertTo-CABAbsolutePath -Path $tmp -Source 'test'
        [System.IO.Path]::IsPathRooted($r) | Should -BeTrue
    }
    It 'ConvertTo-CABGitdirPattern handles spaces in paths' {
        $r = ConvertTo-CABGitdirPattern -Path '/tmp/cab path/ws'
        $r | Should -Be '/tmp/cab path/ws/'
    }
}

Describe 'Step 70 — UTF-8 encoding (regression v1.2.0)' {
    BeforeEach {
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "cab-utf-$(Get-Random)"
        [void](New-Item -ItemType Directory -Path $script:tempHome -Force)
        $script:tempWs = Join-Path $script:tempHome 'ws'
        [void](New-Item -ItemType Directory -Path $script:tempWs -Force)
        $script:fakeGlobal = Join-Path $script:tempHome '.gitconfig'
        function Get-CABGlobalGitconfigPath { $script:fakeGlobal }

        $env:CA_BOOTSTRAP_GIT_NAME  = 'Émilie Müller'
        $env:CA_BOOTSTRAP_GIT_EMAIL = 'emilie@example.com'
        Set-CABPromptMode -Unattended $true -Answers @{ 'identity.configure' = 'yes' }
        $env:CA_BOOTSTRAP_STATE = $script:tempHome
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'

        $script:context = @{
            RepoRoot       = (Resolve-Path "$PSScriptRoot/../..").Path
            WorkspacePath  = $script:tempWs
            Unattended     = $true
        }
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        Unlock-CABSession
        Set-CABPromptMode -Unattended $false -Answers @{}
        Remove-Item Env:CA_BOOTSTRAP_GIT_NAME, Env:CA_BOOTSTRAP_GIT_EMAIL, Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item -Recurse -Force $script:tempHome -ErrorAction SilentlyContinue
        }
    }

    It 'workspace .gitconfig is valid UTF-8 with non-ASCII name' {
        $null = Invoke-CABStep70 -Context $script:context
        $wsConfig = Join-Path $script:tempWs '.gitconfig'
        Test-Path $wsConfig | Should -BeTrue
        # Read raw bytes and decode as UTF-8 — if Set-Content used the system
        # codepage on Windows, "Émilie" would be mangled to question marks.
        $bytes = [System.IO.File]::ReadAllBytes($wsConfig)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Match 'Émilie Müller'
    }

    It 'global .gitconfig still parses with non-ASCII path content' {
        $null = Invoke-CABStep70 -Context $script:context
        & git config -f $script:fakeGlobal --list 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Step 70 — re-run idempotency under UTF-8 (encoding round-trip)' {
    BeforeEach {
        $script:tempHome = Join-Path ([System.IO.Path]::GetTempPath()) "cab-utf2-$(Get-Random)"
        [void](New-Item -ItemType Directory -Path $script:tempHome -Force)
        $script:tempWs = Join-Path $script:tempHome 'ws'
        [void](New-Item -ItemType Directory -Path $script:tempWs -Force)
        $script:fakeGlobal = Join-Path $script:tempHome '.gitconfig'
        function Get-CABGlobalGitconfigPath { $script:fakeGlobal }

        $env:CA_BOOTSTRAP_GIT_NAME  = 'Émilie'
        $env:CA_BOOTSTRAP_GIT_EMAIL = 'e@example.com'
        Set-CABPromptMode -Unattended $true -Answers @{ 'identity.configure' = 'yes' }
        $env:CA_BOOTSTRAP_STATE = $script:tempHome
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'

        $script:context = @{
            RepoRoot       = (Resolve-Path "$PSScriptRoot/../..").Path
            WorkspacePath  = $script:tempWs
            Unattended     = $true
        }
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        Unlock-CABSession
        Set-CABPromptMode -Unattended $false -Answers @{}
        Remove-Item Env:CA_BOOTSTRAP_GIT_NAME, Env:CA_BOOTSTRAP_GIT_EMAIL, Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempHome -and (Test-Path $script:tempHome)) {
            Remove-Item -Recurse -Force $script:tempHome -ErrorAction SilentlyContinue
        }
    }

    It 're-running step 70 does not duplicate the includeIf block' {
        $null = Invoke-CABStep70 -Context $script:context
        $null = Invoke-CABStep70 -Context $script:context
        $blocks = (Get-Content $script:fakeGlobal | Where-Object { $_ -match '^\s*\[includeIf\s+"gitdir:' }).Count
        $blocks | Should -Be 1 -Because 'second run must detect the existing includeIf via UTF-8 read of the global config'
    }
}
