#requires -Version 7.0
# tests/lib/undo-select-folders.tests.ps1 — regression: Select-CABUndoEntry
# -Target folders was broken by operator-precedence bug (cycle 16, PR #74).
# The -in clause without @(...) and parens caused PowerShell to misparse the
# RHS as a comma-expression involving -and, so the filter never matched.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'commands/undo.ps1')
}

Describe 'Select-CABUndoEntry -Target folders' {
    It 'selects all folder-related actions and excludes unrelated + workspace-root entries' {
        $entries = @(
            [pscustomobject]@{ action = 'create_folder';       path = '/tmp/a' }
            [pscustomobject]@{ action = 'rename_folder';       from = '/tmp/old'; to = '/tmp/new' }
            [pscustomobject]@{ action = 'remove_empty_folder'; path = '/tmp/b' }
            [pscustomobject]@{ action = 'clone_repo';          repo = 'x/y' }
            [pscustomobject]@{ action = 'create_folder';       path = '/tmp/ws'; is_workspace_root = $true }
        )
        $selected = Select-CABUndoEntry -Entries $entries -Target 'folders'
        @($selected).Count | Should -Be 3
        ($selected | ForEach-Object { $_.action }) -join ',' | Should -Be 'create_folder,rename_folder,remove_empty_folder'
    }
}
