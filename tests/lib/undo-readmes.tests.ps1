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

Describe 'Undo README reversers' {
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

    It 'marks refresh_readme as a noop so it can be closed out in the journal' {
        $target = Join-Path $script:tmp 'README.md'
        Set-Content -Path $target -Value '# template' -Encoding utf8

        $entry = [ordered]@{
            id        = 3
            step      = 'repair'
            action    = 'refresh_readme'
            path      = $target
            template  = (Join-Path $script:tmp 'tpl.md')
            timestamp = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'noop'
        (Test-Path $target) | Should -BeTrue
    }

    It 'refresh_readme with previous_content restores the original bytes byte-for-byte' {
        # PR #83: the repair --target folder-readmes capture path
        # base64-encodes the pre-overwrite README before writing the
        # template over it. Undo decodes the snapshot and rewrites the
        # file with the original bytes — including custom line endings,
        # trailing whitespace, or user prose that the template overwrote.
        $target  = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'tpl.md'
        Set-Content -Path $target -Value '# template (overwritten)' -Encoding utf8
        $original = "# user drift`r`n`r`nThis paragraph had **markdown** and trailing whitespace.   `r`n"
        $originalBytes = [System.Text.Encoding]::UTF8.GetBytes($original)
        $b64 = [Convert]::ToBase64String($originalBytes)

        $entry = [ordered]@{
            id                = 4
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $b64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'ok'
        $r.details | Should -Match 'Restored'
        # Verify byte-for-byte fidelity — line endings + trailing
        # whitespace MUST survive the round-trip, not just text equality.
        $restoredBytes = [System.IO.File]::ReadAllBytes($target)
        $restoredBytes.Length | Should -Be $originalBytes.Length
        for ($i = 0; $i -lt $originalBytes.Length; $i++) {
            $restoredBytes[$i] | Should -Be $originalBytes[$i]
        }
    }

    It 'refresh_readme fails clearly when previous_content is malformed base64' {
        # A manually-edited journal entry could carry junk in
        # previous_content. Undo must surface that as 'fail' (so the
        # operator sees what went wrong), not 'ok' with a corrupt file
        # on disk and not 'noop' which would silently swallow the error.
        $target = Join-Path $script:tmp 'README.md'
        Set-Content -Path $target -Value '# template' -Encoding utf8

        $entry = [ordered]@{
            id                = 5
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = (Join-Path $script:tmp 'tpl.md')
            previous_content  = 'this-is-not-valid-base64!!!'
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'fail'
        $r.details | Should -Match 'base64'
    }
}

