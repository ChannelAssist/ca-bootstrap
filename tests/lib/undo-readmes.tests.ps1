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
        #
        # Per the cycle-7 safety contract: the divergence guard requires
        # the template still be on disk AND the current README to
        # match it. Seed both so this happy-path test pins the
        # byte-for-byte fidelity of the restore step itself, not the
        # safety-skip path.
        $target  = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'tpl.md'
        $templateContent = '# template (overwritten)'
        Set-Content -Path $template -Value $templateContent -Encoding utf8 -NoNewline
        Set-Content -Path $target   -Value $templateContent -Encoding utf8 -NoNewline
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

    It 'refresh_readme restores a 0-byte (empty) README rather than silently noop-ing' {
        # PR #83 cycle-1 review pinned: base64 of an empty byte[] is
        # an empty string, and the previous `if (-not $b64) { noop }`
        # branch collapsed "missing key" with "captured empty file"
        # — so an empty drifted README was silently un-restorable.
        # Capture is detected by key presence now; empty content
        # round-trips.
        # Per cycle-7 safety contract: divergence guard requires the
        # template still be on disk AND current README to match. Seed
        # both with identical content so the restore proceeds through
        # the safe path and writes 0 bytes.
        $target  = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'tpl.md'
        $templateContent = '# template (overwritten)'
        Set-Content -Path $template -Value $templateContent -Encoding utf8 -NoNewline
        Set-Content -Path $target   -Value $templateContent -Encoding utf8 -NoNewline

        # Empty drift: 0 bytes → base64 of empty byte[] is "".
        $emptyBytes = [byte[]]@()
        $emptyB64   = [Convert]::ToBase64String($emptyBytes)
        $emptyB64 | Should -BeExactly ''

        $entry = [ordered]@{
            id                = 6
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $emptyB64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'ok'
        $r.details | Should -Match 'Restored'
        # File exists, length is 0.
        (Test-Path $target -PathType Leaf) | Should -BeTrue
        ([System.IO.File]::ReadAllBytes($target)).Length | Should -Be 0
    }

    It 'refresh_readme fails clearly when previous_content key is present but null' {
        # PR #83 cycle-2 review pinned: a journal round-trip through
        # powershell-yaml can produce `previous_content:` with no value,
        # which deserializes to $null. The previous code path cast
        # [string]$null → '' → treated it as a valid base64 of an empty
        # README → silently overwrote the file with 0 bytes.
        #
        # Null is now treated as a corrupt entry: status=fail with a
        # message naming the corruption so the operator can resolve it.
        # The empty-string case (a legitimate captured empty README)
        # still restores — that's the test above.
        $target = Join-Path $script:tmp 'README.md'
        Set-Content -Path $target -Value '# template (must survive)' -Encoding utf8

        # Use a real hashtable so ContainsKey('previous_content') is
        # true and the value-via-indexer is $null (mirrors the
        # powershell-yaml deserialization of `previous_content:`).
        $entry = @{
            id                = 7
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = (Join-Path $script:tmp 'tpl.md')
            previous_content  = $null
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'fail'
        $r.details | Should -Match 'null'
        # The file must NOT have been clobbered to 0 bytes.
        (Get-Content -Raw $target) | Should -Match 'template \(must survive\)'
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

    It 'refresh_readme returns skip when the README has diverged from the template (user edited after repair)' {
        # PR #83 cycle-4 review pinned: an unconditional restore would
        # clobber user edits made after the repair overwrote the
        # README. seed_readme already uses a template-hash check
        # before reversing; refresh_readme now matches that pattern.
        $target   = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'tpl.md'

        # Seed: template on disk + the file diverges from it (operator
        # edited after repair). Pre-overwrite content captured.
        Set-Content -Path $template -Value '# template (canonical)' -Encoding utf8 -NoNewline
        Set-Content -Path $target   -Value '# template with USER EDIT after repair' -Encoding utf8 -NoNewline

        # Pre-overwrite content the operator would lose if we forced restore.
        $originalDrift = '# original drift before repair'
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($originalDrift))

        $entry = [ordered]@{
            id                = 8
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $b64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'skip'
        $r.details | Should -Match 'edited since repair'
        # Preserve the user's edit — must NOT have been overwritten.
        (Get-Content -Raw $target) | Should -Match 'USER EDIT'
        (Get-Content -Raw $target) | Should -Not -Match 'original drift'
    }

    It 'refresh_readme proceeds with restore when the README still matches the template (no user edit)' {
        # Companion to the diverged test above: when current README
        # hash == template hash, no user has edited since repair, so
        # the restore is safe and proceeds normally.
        $target   = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'tpl.md'

        $templateContent = '# template (canonical)'
        Set-Content -Path $template -Value $templateContent -Encoding utf8 -NoNewline
        Set-Content -Path $target   -Value $templateContent -Encoding utf8 -NoNewline

        $originalDrift = '# original drift'
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($originalDrift))

        $entry = [ordered]@{
            id                = 9
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $b64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'ok'
        (Get-Content -Raw $target) | Should -Match 'original drift'
    }

    It 'refresh_readme returns fail when the divergence-guard hash compute errors (never silently proceeds)' {
        # PR #83 cycle-6 review pinned: Get-FileHash defaults to
        # -ErrorAction Continue, so a transient read/permission
        # failure on EITHER side of the divergence check would
        # produce $null hashes; $null -ne $null evaluates to false,
        # and the guard would have advertised "no divergence" → the
        # restore would proceed and clobber user edits.
        #
        # Now: -ErrorAction Stop on both Get-FileHash calls, wrapped
        # in try/catch. Hash failure → status=fail with a message
        # naming the comparator failure + the recovery recipe. The
        # restore is refused, so user edits remain intact.
        $target   = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'tpl.md'
        Set-Content -Path $template -Value '# template' -Encoding utf8 -NoNewline
        Set-Content -Path $target   -Value '# template' -Encoding utf8 -NoNewline

        # Force Get-FileHash to throw the same way a transient I/O
        # failure would. The mock matches the SPECIFIC parameter
        # filter on the actual undo call (-Path $target with -Stop)
        # so we don't break unrelated Get-FileHash usage in the same
        # process.
        Mock -CommandName Get-FileHash -MockWith { throw 'access denied (simulated)' } -ParameterFilter {
            $Path -eq $target
        }

        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('# would-be restored drift'))
        $entry = [ordered]@{
            id                = 10
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $b64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'fail'
        $r.details | Should -Match 'compare README to template'
        # Critical: the file must NOT have been overwritten with the
        # would-be restored content.
        (Get-Content -Raw $target) | Should -Match '# template'
        (Get-Content -Raw $target) | Should -Not -Match 'would-be restored'
    }

    It 'refresh_readme returns skip when the recorded template is no longer on disk and the README is present' {
        # PR #83 cycle-7 review pinned: my cycle-4 fallback of "if
        # template missing, just write" was wrong. Without the
        # template we have no signal about whether the current
        # README still matches the post-repair content, so we have
        # to assume divergence is possible and refuse to overwrite.
        # Matches the seed_readme arm at undo.ps1:178-180 exactly.
        $target  = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'absent-template.md'
        Set-Content -Path $target -Value '# user might have edited this' -Encoding utf8 -NoNewline
        # NOTE: $template path NOT written to disk.

        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('# would-be restored drift'))
        $entry = [ordered]@{
            id                = 11
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $b64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'skip'
        $r.details | Should -Match 'Template no longer at recorded path'
        # The user's potentially-edited content must be preserved.
        (Get-Content -Raw $target) | Should -Match 'user might have edited'
        (Get-Content -Raw $target) | Should -Not -Match 'would-be restored'
    }

    It 'refresh_readme proceeds with restore when the README target file does not exist at all' {
        # Companion to the template-missing-skip test: when the target
        # README is absent, no divergence is possible — there is no
        # current content to clobber, only an empty file slot to fill.
        # Restore should proceed without requiring the template
        # comparator. (This is the "operator manually deleted the
        # README after repair" path; restoring the captured drift
        # is the right behavior.)
        $target  = Join-Path $script:tmp 'README.md'
        $template = Join-Path $script:tmp 'absent-template.md'
        # Neither target nor template on disk.

        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('# restored drift'))
        $entry = [ordered]@{
            id                = 12
            step              = 'repair'
            action            = 'refresh_readme'
            path              = $target
            template          = $template
            previous_content  = $b64
            timestamp         = (Get-Date -Format o)
        }

        $r = Invoke-CABUndoEntry -Entry $entry
        $r.status | Should -Be 'ok'
        (Get-Content -Raw $target) | Should -Match 'restored drift'
    }
}

