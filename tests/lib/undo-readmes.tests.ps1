#requires -Version 7.0
# tests/lib/undo-readmes.tests.ps1 — regression: undo seed_readme actually
# removes the README (cycle 10 caught field access bug that made it noop).

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'commands/undo.ps1')
}

Describe 'Undo seed_readme reverser' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cab-undo-readme-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-undo-readme-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState
        New-Item -ItemType Directory -Path $script:tmp -Force | Out-Null
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        try { Unlock-CABSession } catch {}
        foreach ($p in @($script:tmp, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'removes a seeded README when path + template match byte-for-byte' {
        $template = Join-Path $script:tmp 'tpl.md'
        $target   = Join-Path $script:tmp 'README.md'
        Set-Content -Path $template -Value '# template' -Encoding utf8
        Copy-Item -Path $template -Destination $target

        # Construct an entry the way Add-CABJournalEntry stores it (flat fields).
        $entry = [ordered]@{
            id        = 1
            step      = '50-folders'
            action    = 'seed_readme'
            path      = $target
            template  = $template
            timestamp = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'ok'
        (Test-Path $target) | Should -BeFalse
    }

    It 'preserves a user-edited README (hash divergence)' {
        $template = Join-Path $script:tmp 'tpl.md'
        $target   = Join-Path $script:tmp 'README.md'
        Set-Content -Path $template -Value '# template' -Encoding utf8
        Set-Content -Path $target   -Value '# my edits'  -Encoding utf8

        $entry = [ordered]@{
            id        = 2
            step      = '50-folders'
            action    = 'seed_readme'
            path      = $target
            template  = $template
            timestamp = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'skip'
        (Test-Path $target) | Should -BeTrue
        (Get-Content -Raw $target) | Should -Match 'my edits'
    }
}
