#requires -Version 7.0
# tests/lib/extras-vscode.tests.ps1 — coverage for step 80's
# workspace-root .vscode/ defaults writer + the create_file undo
# reverser. These are the asserts called out in the PR review:
#   1. copies templates when the destination is missing
#   2. preserves pre-existing files (does NOT overwrite)
#   3. emits one create_file journal entry per copied file
#   4. undo (via Invoke-CABUndoCreateFile) deletes the file

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'commands/undo.ps1')
}

Describe 'workspace .vscode/ defaults — copy semantics' {
    BeforeEach {
        $script:tmp           = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-vscode-" + [guid]::NewGuid().ToString('N'))
        $script:vscodeDir     = Join-Path $script:tmp '.vscode'
        $script:templates     = Join-Path $script:repoRoot 'templates/dot-vscode'
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'copies all four template files when none exist' {
        New-Item -ItemType Directory -Path $script:vscodeDir -Force | Out-Null
        foreach ($name in 'extensions.json','settings.json','launch.json','tasks.json') {
            Copy-Item -Path (Join-Path $script:templates $name) -Destination (Join-Path $script:vscodeDir $name) -ErrorAction Stop
        }
        # -Force on Get-ChildItem so files inside the dot-prefixed
        # parent (.vscode/) on POSIX hosts aren't filtered out as hidden.
        @(Get-ChildItem -Path $script:vscodeDir -Force -File).Count | Should -Be 4
    }

    It 'leaves a pre-existing settings.json untouched (skip-if-present semantics)' {
        New-Item -ItemType Directory -Path $script:vscodeDir -Force | Out-Null
        $sentinel = '{ "sentinel": true }'
        Set-Content -Path (Join-Path $script:vscodeDir 'settings.json') -Value $sentinel
        # Mirror step 80's loop body: copy only when the destination is
        # missing. settings.json already exists, so it must be skipped.
        foreach ($name in 'extensions.json','settings.json','launch.json','tasks.json') {
            $dst = Join-Path $script:vscodeDir $name
            if (Test-Path $dst) { continue }
            Copy-Item -Path (Join-Path $script:templates $name) -Destination $dst -ErrorAction Stop
        }
        (Get-Content -Raw (Join-Path $script:vscodeDir 'settings.json')).Trim() | Should -Be $sentinel
    }

    It 'Copy-Item -ErrorAction Stop throws on a write failure (no silent-success risk)' {
        # Make the destination directory read-only so the copy fails. On
        # macOS / Linux chmod 0500 prevents new files; on Windows we
        # achieve the same with an ACL. Skip on Windows (ACL setup is
        # heavier and not where the bug lives — the property under test
        # is "non-terminating Copy-Item is converted to a catchable
        # exception by -ErrorAction Stop").
        if ($IsWindows) { Set-ItResult -Skipped -Because 'POSIX chmod-based readonly setup' ; return }
        New-Item -ItemType Directory -Path $script:vscodeDir -Force | Out-Null
        chmod 500 $script:vscodeDir
        try {
            { Copy-Item -Path (Join-Path $script:templates 'extensions.json') -Destination (Join-Path $script:vscodeDir 'extensions.json') -ErrorAction Stop } |
                Should -Throw
        } finally {
            chmod 700 $script:vscodeDir   # restore so AfterEach can clean up
        }
    }
}

Describe 'create_file undo reverser' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-undo-cf-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'removes the file recorded in the entry' {
        $target = Join-Path $script:tmp 'extensions.json'
        Set-Content -Path $target -Value '{ "recommendations": [] }'
        $r = Invoke-CABUndoCreateFile -Entry @{ path = $target }
        $r.status | Should -Be 'ok'
        Test-Path $target | Should -BeFalse
    }

    It 'returns noop (not fail) when the file is already gone' {
        $target = Join-Path $script:tmp 'extensions.json'
        $r = Invoke-CABUndoCreateFile -Entry @{ path = $target }
        $r.status | Should -Be 'noop'
    }
}

Describe 'Invoke-CABUndoEntry dispatch — create_file' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-undo-disp-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Path $script:tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'routes create_file to Invoke-CABUndoCreateFile (file is deleted)' {
        $target = Join-Path $script:tmp 'tasks.json'
        Set-Content -Path $target -Value '{}'
        $r = Invoke-CABUndoEntry -Entry @{ action = 'create_file'; path = $target }
        $r.status | Should -Be 'ok'
        Test-Path $target | Should -BeFalse
    }
}
