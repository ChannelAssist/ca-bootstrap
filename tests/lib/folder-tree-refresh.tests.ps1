#requires -Version 7.0
# tests/lib/folder-tree-refresh.tests.ps1 — repair --target folder-tree-refresh
# regenerates the "## Tree" section of each workspace folder's README from
# manifest/repos.yaml, idempotently and without touching any other content.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'lib/folder-tree-refresh.ps1')
    . (Join-Path $script:repoRoot 'commands/repair.ps1')
}

Describe 'Get-CABFolderTreeBlock' {
    BeforeAll {
        $script:manifest = @{
            groups = @(
                @{ name = 'g1'; repos = @(
                    @{ repo = 'x/repo-b'; into = 'ca-platform/repo-b' },
                    @{ repo = 'x/repo-a'; into = 'ca-platform/repo-a' }
                )},
                @{ name = 'g2'; repos = @(
                    @{ repo = 'x/repo-c'; into = 'ca-platform/repo-c' },
                    @{ repo = 'x/other';  into = 'cm-product/other' }
                )}
            )
        }
    }

    It 'returns folder/ + sorted direct children with branch glyphs' {
        $tree = Get-CABFolderTreeBlock -FolderPath 'ca-platform' -ReposManifest $script:manifest
        $tree | Should -Be "ca-platform/`n├── repo-a/`n├── repo-b/`n└── repo-c/"
    }

    It 'returns only the root line when the folder has no repos' {
        $tree = Get-CABFolderTreeBlock -FolderPath 'ca-work-dirs' -ReposManifest $script:manifest
        $tree | Should -Be 'ca-work-dirs/'
    }

    It 'ignores nested paths beyond direct children' {
        $m = @{ groups = @(@{ repos = @(
            @{ into = 'ca-platform/svc/sub' },
            @{ into = 'ca-platform/svc' }
        )}) }
        $tree = Get-CABFolderTreeBlock -FolderPath 'ca-platform' -ReposManifest $m
        $tree | Should -Be "ca-platform/`n└── svc/"
    }
}

Describe 'Update-CABFolderReadmeTree' {
    BeforeEach {
        $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tree-update-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
        $script:readme = Join-Path $script:tmpDir 'README.md'
    }
    AfterEach {
        if (Test-Path $script:tmpDir) { Remove-Item -Recurse -Force $script:tmpDir -ErrorAction SilentlyContinue }
    }

    It 'returns no-readme when the file does not exist' {
        Update-CABFolderReadmeTree -ReadmePath (Join-Path $script:tmpDir 'missing.md') -Tree 'x/' | Should -Be 'no-readme'
    }

    It 'returns no-section when the README lacks a "## Tree" heading' {
        Set-Content -Path $script:readme -Value "# title`n`nno tree here`n"
        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree 'x/' | Should -Be 'no-section'
    }

    It 'returns no-fence when "## Tree" exists but has no following fenced block' {
        Set-Content -Path $script:readme -Value "# title`n`n## Tree`n`nprose only`n"
        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree 'x/' | Should -Be 'no-fence'
    }

    It 'replaces the fenced tree block on first run and reports kept on the second' {
        $content = @(
            '# ca-platform',
            '',
            'Intro paragraph.',
            '',
            '## Tree',
            '',
            '```',
            'ca-platform/',
            '└── stale-only/',
            '```',
            '',
            '## Refresh',
            '',
            'Some trailing prose.'
        ) -join "`n"
        Set-Content -Path $script:readme -Value $content -NoNewline

        $newTree = "ca-platform/`n├── repo-a/`n└── repo-b/"

        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree $newTree | Should -Be 'updated'
        $after = Get-Content -Raw -Path $script:readme
        $after | Should -Match 'repo-a/'
        $after | Should -Match 'repo-b/'
        $after | Should -Not -Match 'stale-only/'
        # Surrounding content preserved.
        $after | Should -Match 'Intro paragraph'
        $after | Should -Match '## Refresh'
        $after | Should -Match 'Some trailing prose'

        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree $newTree | Should -Be 'kept'
    }

    It 'updates a CRLF-line-ended README and is idempotent on the second run' {
        # Regression test for the CRLF handling bug PR #81 cycle-1
        # review identified. Without `\r?$` in the heading/fence
        # regexes (and without EOL-aware body rewriting), Windows-
        # authored READMEs failed to match at all and never updated.
        $crlfContent = (@(
            '# ca-platform',
            '',
            'Intro paragraph.',
            '',
            '## Tree',
            '',
            '```',
            'ca-platform/',
            '└── stale-only/',
            '```',
            '',
            'Trailing prose.'
        ) -join "`r`n")
        Set-Content -Path $script:readme -Value $crlfContent -NoNewline

        $newTree = "ca-platform/`n├── repo-a/`n└── repo-b/"

        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree $newTree | Should -Be 'updated'
        $after = Get-Content -Raw -Path $script:readme
        $after | Should -Match 'repo-a/'
        $after | Should -Not -Match 'stale-only/'
        # The native line ending must be preserved — without the EOL
        # detection, the rewrite would have normalized to LF and broken
        # idempotency on the next run.
        $after | Should -Match "`r`n"

        # Second run reports kept (no double-rewrite).
        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree $newTree | Should -Be 'kept'
    }

    It 'preserves an existing UTF-8 BOM on rewrite' {
        # The function's contract claims BOM preservation. Verify the
        # output bytes start with EF BB BF when the input did, and that
        # a non-BOM input round-trips without acquiring one.
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $content = "# title`n`n## Tree`n`n```````nold/`n```````n"
        $bytes = $bom + [System.Text.Encoding]::UTF8.GetBytes($content)
        [System.IO.File]::WriteAllBytes($script:readme, $bytes)

        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree 'new/' | Should -Be 'updated'
        $afterBytes = [System.IO.File]::ReadAllBytes($script:readme)
        # First three bytes must still be the BOM.
        $afterBytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'leaves a later fenced block untouched (only the one under ## Tree is rewritten)' {
        $content = @(
            '## Tree',
            '',
            '```',
            'old/',
            '```',
            '',
            '## Examples',
            '',
            '```bash',
            'do not touch me',
            '```'
        ) -join "`n"
        Set-Content -Path $script:readme -Value $content -NoNewline

        Update-CABFolderReadmeTree -ReadmePath $script:readme -Tree 'new/' | Should -Be 'updated'
        $after = Get-Content -Raw -Path $script:readme
        $after | Should -Match 'new/'
        $after | Should -Not -Match 'old/'
        $after | Should -Match 'do not touch me'
    }
}

Describe 'Invoke-CABFolderTreeRefresh — end-to-end' {
    BeforeEach {
        $script:tmpWs    = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tree-ws-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tree-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState
        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null

        # Seed a workspace with two folder READMEs whose Tree blocks
        # are deliberately stale (don't match the live manifest).
        foreach ($f in 'ca-tools','ca-docs','ca-platform') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $f) -Force | Out-Null
        }
        # Heredoc style: easier to keep the fenced ``` markers correct
        # than wrestling PowerShell's backtick escape inside `"..."`
        # (six-backtick sequences confused the original literal — the
        # adjacent `\n` was meant to be a newline but PS treats `\n`
        # as the two-char string `\n`; only ``n`` produces a newline).
        $staleTools = @"
# ca-tools

## Tree

``````
ca-tools/
└── obsolete/
``````
"@
        $stalePlat = @"
# ca-platform

## Tree

``````
ca-platform/
└── obsolete/
``````
"@
        Set-Content -Path (Join-Path $script:tmpWs 'ca-tools/README.md')    -Value $staleTools -NoNewline
        Set-Content -Path (Join-Path $script:tmpWs 'ca-platform/README.md') -Value $stalePlat  -NoNewline
        # ca-docs intentionally has no README on disk — should be skipped.

        $script:ctx = @{ RepoRoot = $script:repoRoot; WorkspacePath = $script:tmpWs; Version = 'test' }
    }
    AfterEach {
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'rewrites the tree of every folder README to match the live manifest' {
        $r = Invoke-CABFolderTreeRefresh -Context $script:ctx
        $r.status | Should -Be 'ok'
        $r.updated | Should -Contain 'ca-tools'
        $r.updated | Should -Contain 'ca-platform'
        # ca-docs has no README on disk → skipped, not failed.
        $r.skipped | Should -Contain 'ca-docs'

        $toolsAfter = Get-Content -Raw -Path (Join-Path $script:tmpWs 'ca-tools/README.md')
        $toolsAfter | Should -Match 'ca-bootstrap/'
        $toolsAfter | Should -Not -Match 'obsolete/'

        $platAfter = Get-Content -Raw -Path (Join-Path $script:tmpWs 'ca-platform/README.md')
        $platAfter | Should -Match 'ca-ai-agents/'
        $platAfter | Should -Match 'ca-privacy-gate/'
        $platAfter | Should -Not -Match 'obsolete/'
    }

    It 'is a no-op on the second invocation (idempotent)' {
        Invoke-CABFolderTreeRefresh -Context $script:ctx | Out-Null
        $r = Invoke-CABFolderTreeRefresh -Context $script:ctx
        $r.status | Should -Be 'ok'
        $r.updated.Count | Should -Be 0
        $r.kept | Should -Contain 'ca-tools'
        $r.kept | Should -Contain 'ca-platform'
        $r.details | Should -Match 'no-op'
    }

    It 'fails fast when WorkspacePath is missing from the context' {
        $r = Invoke-CABFolderTreeRefresh -Context @{ RepoRoot = $script:repoRoot }
        $r.status | Should -Be 'fail'
        $r.details | Should -Match 'Workspace'
    }

    It 'is reachable via Invoke-CABRepairTarget dispatch' {
        $r = Invoke-CABRepairTarget -Target 'folder-tree-refresh' -Context $script:ctx
        $r.ok | Should -BeTrue
    }
}
