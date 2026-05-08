#requires -Version 7.0
# tests/lib/extras-vscode.tests.ps1 — coverage for step 80's
# workspace-root .vscode/ defaults writer + the create_file undo
# reverser.
#
# Tests in this file:
#   1. Invoke-CABStep80 end-to-end (unattended + temp state dir):
#      - copies all 4 templates when none exist
#      - skips a pre-existing file (sentinel survives)
#      - emits one create_file journal entry per file written
#      - skips the .vscode/ block (warn) when Context.RepoRoot is null
#   2. Building blocks:
#      - Copy-Item -ErrorAction Stop is terminating
#      - Invoke-CABUndoCreateFile deletes the recorded path
#      - Invoke-CABUndoEntry routes 'create_file' to the reverser

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path

    # Redirect ca-bootstrap's per-user state dir to a temp location so
    # journal writes from these tests don't pollute ~/.ca-bootstrap.
    # MUST be set before dot-sourcing journal.ps1 (it captures the env
    # var at module load).
    $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-test-state-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tmpState -Force | Out-Null
    $env:CA_BOOTSTRAP_STATE = $script:tmpState

    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/platform.ps1')
    . (Join-Path $script:repoRoot 'lib/prompts.ps1')
    . (Join-Path $script:repoRoot 'lib/answers.ps1')
    . (Join-Path $script:repoRoot 'lib/git-ops.ps1')
    . (Join-Path $script:repoRoot 'lib/tools.ps1')
    . (Join-Path $script:repoRoot 'commands/undo.ps1')
    . (Join-Path $script:repoRoot 'steps/80-extras.ps1')
}

AfterAll {
    if ($script:tmpState -and (Test-Path $script:tmpState)) {
        Remove-Item -Path $script:tmpState -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
}

Describe 'Invoke-CABStep80 end-to-end — workspace .vscode/ defaults' {
    BeforeEach {
        # Fresh temp workspace + fresh journal session per test so the
        # asserts are independent.
        $script:workspace = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-step80-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:workspace -Force | Out-Null

        # Reset journal state file so each test starts clean.
        Remove-Item -Path (Join-Path $script:tmpState 'journal.yaml') -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $script:tmpState 'session.lock') -ErrorAction SilentlyContinue

        # Drive Read-CABConfirm via the unattended-mode path: pre-stuff
        # answers in $Script:CABootstrapAnswers and flip the unattended
        # flag. Cleaner than mocking — it's the same code path
        # `setup -Unattended` exercises in production.
        $Script:CABootstrapUnattended = $true
        $Script:CABootstrapAnswers    = @{
            'extras.vscode_workspace_file' = $false   # no cloned repos in temp ws
            'extras.vscode_defaults'       = $true    # the block under test
            'extras.ca_claude_plugin'      = $false
            'extras.ca_copilot_plugin'     = $false
            'extras.wsl_ubuntu_2204'       = $false
        }

        Start-CABSession -Command 'setup' -Version 'test' -WorkspacePath $script:workspace | Out-Null
    }
    AfterEach {
        # Release the lock and clean up the workspace.
        Unlock-CABSession -ErrorAction SilentlyContinue
        if ($script:workspace -and (Test-Path $script:workspace)) {
            Remove-Item -Path $script:workspace -Recurse -Force -ErrorAction SilentlyContinue
        }
        $Script:CABootstrapUnattended = $false
        $Script:CABootstrapAnswers    = $null
    }

    It 'copies all 4 templates and emits one create_file journal entry per file' {
        $ctx = @{
            WorkspacePath = $script:workspace
            RepoRoot      = $script:repoRoot
            StepOrdinal   = 8
            TotalSteps    = 8
        }
        $result = Invoke-CABStep80 -Context $ctx
        $result.status | Should -Be 'ok'

        $vscodeDir = Join-Path $script:workspace '.vscode'
        $files = @(Get-ChildItem -Path $vscodeDir -Force -File | Where-Object { $_.Name -in 'extensions.json','settings.json','launch.json','tasks.json' })
        $files.Count | Should -Be 4

        $createFileEntries = @(Get-CABJournalEntry -Action 'create_file' -IncludeUndone)
        $createFileEntries.Count | Should -Be 4
        # Each entry's path should resolve to one of the 4 expected files.
        $entryNames = $createFileEntries | ForEach-Object { Split-Path $_.path -Leaf } | Sort-Object
        ($entryNames -join ',') | Should -Be 'extensions.json,launch.json,settings.json,tasks.json'
    }

    It 'preserves a pre-existing settings.json (no overwrite, no journal entry for it)' {
        $vscodeDir = Join-Path $script:workspace '.vscode'
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
        $sentinel = '{ "sentinel": true }'
        Set-Content -Path (Join-Path $vscodeDir 'settings.json') -Value $sentinel

        $ctx = @{ WorkspacePath = $script:workspace; RepoRoot = $script:repoRoot; StepOrdinal = 8; TotalSteps = 8 }
        Invoke-CABStep80 -Context $ctx | Out-Null

        # Sentinel survives.
        (Get-Content -Raw (Join-Path $vscodeDir 'settings.json')).Trim() | Should -Be $sentinel

        # Journal records 3 create_file entries (extensions/launch/tasks),
        # NOT 4 — settings.json was skipped.
        $createFileEntries = @(Get-CABJournalEntry -Action 'create_file' -IncludeUndone)
        $createFileEntries.Count | Should -Be 3
        $entryNames = $createFileEntries | ForEach-Object { Split-Path $_.path -Leaf }
        $entryNames | Should -Not -Contain 'settings.json'
    }

    It 'skips the .vscode/ block (warn) when Context.RepoRoot is null' {
        $ctx = @{ WorkspacePath = $script:workspace; RepoRoot = $null; StepOrdinal = 8; TotalSteps = 8 }
        Invoke-CABStep80 -Context $ctx | Out-Null

        $vscodeDir = Join-Path $script:workspace '.vscode'
        Test-Path $vscodeDir | Should -BeFalse

        $createFileEntries = @(Get-CABJournalEntry -Action 'create_file' -IncludeUndone)
        $createFileEntries.Count | Should -Be 0
    }
}

Describe 'create_file building blocks' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-cf-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Copy-Item -ErrorAction Stop throws on a write failure' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'POSIX chmod-based readonly setup' ; return }
        $vscodeDir = Join-Path $script:tmp '.vscode'
        New-Item -ItemType Directory -Path $vscodeDir -Force | Out-Null
        chmod 500 $vscodeDir
        try {
            { Copy-Item -Path (Join-Path $script:repoRoot 'templates/dot-vscode/extensions.json') -Destination (Join-Path $vscodeDir 'extensions.json') -ErrorAction Stop } |
                Should -Throw
        } finally {
            chmod 700 $vscodeDir
        }
    }

    It 'Invoke-CABUndoCreateFile removes the recorded file' {
        $target = Join-Path $script:tmp 'extensions.json'
        Set-Content -Path $target -Value '{ "recommendations": [] }'
        $r = Invoke-CABUndoCreateFile -Entry @{ path = $target }
        $r.status | Should -Be 'ok'
        Test-Path $target | Should -BeFalse
    }

    It 'Invoke-CABUndoCreateFile returns noop when the file is already gone' {
        $target = Join-Path $script:tmp 'extensions.json'
        $r = Invoke-CABUndoCreateFile -Entry @{ path = $target }
        $r.status | Should -Be 'noop'
    }

    It 'Invoke-CABUndoEntry routes create_file to the reverser' {
        $target = Join-Path $script:tmp 'tasks.json'
        Set-Content -Path $target -Value '{}'
        $r = Invoke-CABUndoEntry -Entry @{ action = 'create_file'; path = $target }
        $r.status | Should -Be 'ok'
        Test-Path $target | Should -BeFalse
    }
}
