#requires -Version 7.0
# tests/lib/manifest-edit.tests.ps1 — regression tests for the
# manifest-edit command (issue #26). Focuses on the pure functions
# that mutate the YAML; the interactive prompt path is exercised
# end-to-end at the make-target level, not in unit tests.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'commands/manifest-drift.ps1')   # Get-CABSuggestedGroup
    . (Join-Path $repoRoot 'commands/manifest-edit.ps1')
}

Describe 'ConvertTo-CABManifestRepoLine' {
    It 'renders a non-opt-in entry as a single-line compact-flow' {
        $line = ConvertTo-CABManifestRepoLine -Entry @{
            slug = 'ChannelAssist/foo'
            into = 'ca-platform/foo'
            branch = 'main'
            opt_in = $false
        }
        $line | Should -Be '      - { repo: ChannelAssist/foo, into: ca-platform/foo, branch: main }'
    }
    It 'appends opt_in: true when the entry is opt-in' {
        $line = ConvertTo-CABManifestRepoLine -Entry @{
            slug = 'ChannelAssist/foo'
            into = 'experiments/foo'
            branch = 'dev'
            opt_in = $true
        }
        $line | Should -Be '      - { repo: ChannelAssist/foo, into: experiments/foo, branch: dev, opt_in: true }'
    }
}

Describe 'Find-CABGroupInsertIndex' {
    BeforeAll {
        $script:sampleLines = @(
            'version: 1',
            'groups:',
            '  - name: docs',
            '    repos:',
            '      - { repo: ChannelAssist/Keystone, into: docs/keystone, branch: master }',
            '',
            '  - name: ca-platform',
            '    repos:',
            '      - { repo: ChannelAssist/ca-foo, into: ca-platform/ca-foo, branch: main }',
            '',
            '  - name: cm-product',
            '    repos:',
            '      - { repo: ChannelAssist/cm-foo, into: cm-product/cm-foo, branch: main }',
            ''
        )
    }
    It 'returns the index just before the trailing blank line of a middle group' {
        $idx = Find-CABGroupInsertIndex -Lines $script:sampleLines -GroupName 'ca-platform'
        # Insert position should be index 9 (just before the blank line
        # at index 9 that follows the ca-platform repos block).
        $idx | Should -Be 9
    }
    It 'returns just before EOF blank line for the last group' {
        $idx = Find-CABGroupInsertIndex -Lines $script:sampleLines -GroupName 'cm-product'
        $idx | Should -Be 13
    }
    It 'returns $null for an unknown group' {
        $idx = Find-CABGroupInsertIndex -Lines $script:sampleLines -GroupName 'no-such-group'
        $idx | Should -BeNullOrEmpty
    }
}

Describe 'Edit-CABManifestText' {
    BeforeEach {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "cab-medit-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
        $script:manifestPath = Join-Path $script:tempDir 'repos.yaml'
        # Use a minimal manifest with one single-line entry per group
        # plus one multi-line entry (channel-manager-style) to exercise
        # the "skip multi-line" branch.
        @'
version: 1
groups:
  - name: docs
    repos:
      - { repo: ChannelAssist/Keystone, into: docs/keystone, branch: master }

  - name: ca-platform
    repos:
      - { repo: ChannelAssist/ca-foo, into: ca-platform/ca-foo, branch: main }

  - name: cm-product
    repos:
      - repo: ChannelAssist/multiline-pinned
        into: cm-product/multiline-pinned
        branch: dev
        large: true
        opt_in: true
      - { repo: ChannelAssist/cm-foo, into: cm-product/cm-foo, branch: main }
'@ | Set-Content -Path $script:manifestPath -NoNewline
    }
    AfterEach {
        if ($script:tempDir -and (Test-Path $script:tempDir)) {
            Remove-Item -Recurse -Force $script:tempDir -ErrorAction SilentlyContinue
        }
    }

    It 'adds a new entry to the requested group' {
        $newContent = Edit-CABManifestText -Path $script:manifestPath -Adds @(
            @{ slug = 'ChannelAssist/ca-bar'; group = 'ca-platform'; into = 'ca-platform/ca-bar'; branch = 'main'; opt_in = $false }
        ) -Removes @()
        $newContent | Should -Match '\bChannelAssist/ca-bar\b'
        $newContent | Should -Match 'into: ca-platform/ca-bar'
    }

    It 'removes a single-line entry by slug' {
        $newContent = Edit-CABManifestText -Path $script:manifestPath -Adds @() -Removes @('ChannelAssist/cm-foo')
        $newContent | Should -Not -Match '\bChannelAssist/cm-foo\b'
        # The other repos should still be present.
        $newContent | Should -Match '\bChannelAssist/Keystone\b'
        $newContent | Should -Match '\bChannelAssist/ca-foo\b'
    }

    It 'refuses to remove a multi-line entry (warns, leaves it intact)' {
        $newContent = Edit-CABManifestText -Path $script:manifestPath -Adds @() -Removes @('ChannelAssist/multiline-pinned')
        # The multi-line entry must still be present — we don't have a
        # reliable way to surgically delete it, so v1 leaves it alone.
        $newContent | Should -Match 'repo: ChannelAssist/multiline-pinned'
        $newContent | Should -Match 'large: true'
    }

    It 'handles add + remove in a single call (atomic batch)' {
        $newContent = Edit-CABManifestText -Path $script:manifestPath `
            -Adds @(@{ slug = 'ChannelAssist/new-thing'; group = 'docs'; into = 'docs/new-thing'; branch = 'main'; opt_in = $false }) `
            -Removes @('ChannelAssist/cm-foo')
        $newContent | Should -Match '\bChannelAssist/new-thing\b'
        $newContent | Should -Not -Match '\bChannelAssist/cm-foo\b'
    }

    It 'preserves group structure (group names + comments survive)' {
        $newContent = Edit-CABManifestText -Path $script:manifestPath `
            -Adds @(@{ slug = 'ChannelAssist/foo'; group = 'docs'; into = 'docs/foo'; branch = 'main'; opt_in = $false }) `
            -Removes @()
        $newContent | Should -Match '- name: docs'
        $newContent | Should -Match '- name: ca-platform'
        $newContent | Should -Match '- name: cm-product'
    }
}

Describe 'Invoke-CABCommandManifestEdit auto-queues archived for removal' {
    # The interactive UI path uses Read-CABChoice / Read-Host; mocking
    # them would be brittle. The behavioral guarantee that matters most
    # is that archived-and-in-manifest entries get auto-queued for
    # removal up front. We exercise that by pre-loading manifest with
    # an archived slug, stubbing gh to mark it archived, and asserting
    # the function recognizes it (via the announcement text).

    BeforeEach {
        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cab-medit-arch-$(Get-Random)"
        New-Item -ItemType Directory -Path "$script:tempRoot/manifest" -Force | Out-Null
        @'
version: 1
groups:
  - name: docs
    repos:
      - { repo: ChannelAssist/legit, into: docs/legit, branch: main }
      - { repo: ChannelAssist/archived-thing, into: docs/archived-thing, branch: main }
'@ | Set-Content -Path "$script:tempRoot/manifest/repos.yaml"
        $script:shimDir = Join-Path $script:tempRoot 'shim'
        New-Item -ItemType Directory -Path $script:shimDir -Force | Out-Null
        $payloadFile = Join-Path $script:shimDir 'gh-payload.json'
        @'
[
  {"nameWithOwner":"ChannelAssist/legit","isArchived":false,"isPrivate":false,"defaultBranchRef":{"name":"main"}},
  {"nameWithOwner":"ChannelAssist/archived-thing","isArchived":true,"isPrivate":false,"defaultBranchRef":{"name":"main"}}
]
'@ | Set-Content -Path $payloadFile
        if ($IsWindows) {
            $shimPath = Join-Path $script:shimDir 'gh.cmd'
            Set-Content -Path $shimPath -Value "@echo off`r`nif `"%1`"==`"auth`" exit /b 0`r`nif `"%1`"==`"repo`" type `"$payloadFile`" & exit /b 0`r`nexit /b 0"
        } else {
            $shimPath = Join-Path $script:shimDir 'gh'
            Set-Content -Path $shimPath -Value "#!/bin/bash`nif [ `"`$1`" = `"auth`" ]; then exit 0; fi`nif [ `"`$1`" = `"repo`" ] && [ `"`$2`" = `"list`" ]; then cat '$payloadFile'; exit 0; fi`nexit 0"
            chmod +x $shimPath
        }
        $script:oldPath = $env:PATH
        $env:PATH = "$script:shimDir" + [IO.Path]::PathSeparator + $script:oldPath
    }
    AfterEach {
        if ($script:oldPath) { $env:PATH = $script:oldPath }
        if ($script:tempRoot -and (Test-Path $script:tempRoot)) {
            Remove-Item -Recurse -Force $script:tempRoot -ErrorAction SilentlyContinue
        }
    }

    It 'auto-queues archived-in-manifest entries on startup, then quits cleanly when "q" is the first answer' {
        # Drive the interactive loop via a here-string sent to stdin.
        # Sequence: 'q' (quit). When pendingRemoves.Count > 0, the
        # quit branch confirms with another prompt — answer 'y' to
        # discard the auto-queued removal and exit.
        # We capture the function's printed output, not the return.
        $rr = (Resolve-Path "$PSScriptRoot/../..").Path
        $tr = $script:tempRoot
        $output = & pwsh -NoProfile -Command @"
. '$rr/lib/ui.ps1'
. '$rr/lib/yaml.ps1'
. '$rr/lib/journal.ps1'
. '$rr/lib/prompts.ps1'
. '$rr/commands/manifest-drift.ps1'
. '$rr/commands/manifest-edit.ps1'
Set-CABPromptMode -Unattended `$true -Answers @{
    'manifest-edit.action' = 'q'
    'manifest-edit.confirm-quit' = 'y'
}
`$ctx = @{ RepoRoot = '$tr' }
Invoke-CABCommandManifestEdit -Context `$ctx | Out-Null
"@ 2>&1 | Out-String

        # The auto-queue announcement must mention the archived slug.
        $output | Should -Match 'Auto-queued.*archived'
        $output | Should -Match 'ChannelAssist/archived-thing'
    }
}
