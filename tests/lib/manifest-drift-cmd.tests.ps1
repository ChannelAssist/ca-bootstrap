#requires -Version 7.0
# tests/lib/manifest-drift-cmd.tests.ps1 — regression tests for the
# manifest-drift maintenance command (issue #18). Verifies:
#   1. Get-CABSuggestedGroup heuristic behavior
#   2. Diff logic produces the expected missing/stale/archived buckets
#      against a controlled manifest + a stubbed `gh` shim on PATH.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'commands/manifest-drift.ps1')
    $script:repoRoot = $repoRoot
}

Describe 'Get-CABSuggestedGroup heuristic' {
    It 'maps ca-* prefix to ca-platform' {
        Get-CABSuggestedGroup -Slug 'ChannelAssist/ca-foo' | Should -Be 'ca-platform'
    }
    It 'maps cm-* prefix and channel-manager to cm-product' {
        Get-CABSuggestedGroup -Slug 'ChannelAssist/cm-bar'         | Should -Be 'cm-product'
        Get-CABSuggestedGroup -Slug 'ChannelAssist/channel-manager' | Should -Be 'cm-product'
    }
    It 'maps .github* and Keystone to docs' {
        Get-CABSuggestedGroup -Slug 'ChannelAssist/.github'         | Should -Be 'docs'
        Get-CABSuggestedGroup -Slug 'ChannelAssist/.github-private' | Should -Be 'docs'
        Get-CABSuggestedGroup -Slug 'ChannelAssist/Keystone'        | Should -Be 'docs'
    }
    It 'falls back to "unsorted" for unknown patterns' {
        Get-CABSuggestedGroup -Slug 'ChannelAssist/random-thing' | Should -Be 'unsorted'
    }
}

Describe 'Invoke-CABCommandManifestDrift diff buckets' {
    BeforeEach {
        $script:tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cab-drift-cmd-$(Get-Random)"
        $manifestDir = Join-Path $script:tempRoot 'manifest'
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null

        # Manifest holds keystone (matches), ca-foo (matches), cm-deleted
        # (no longer on GitHub), and cm-stale-archived (still on GitHub
        # but archived). The stubbed `gh` returns: keystone, ca-foo,
        # ca-new (NOT in manifest), cm-stale-archived (archived=true).
        $manifestYaml = @'
version: 1
default_protocol: https
clone_concurrency: 4
groups:
  - name: docs
    description: Documentation repos
    repos:
      - { repo: ChannelAssist/Keystone, into: docs/keystone, branch: master }
  - name: ca-platform
    description: ChannelAssist platform-wide services
    repos:
      - { repo: ChannelAssist/ca-foo, into: ca-platform/ca-foo, branch: main }
  - name: cm-product
    description: ChannelManager product repos
    repos:
      - { repo: ChannelAssist/cm-deleted, into: cm-product/cm-deleted, branch: main }
      - { repo: ChannelAssist/cm-stale-archived, into: cm-product/cm-stale-archived, branch: main }
'@
        Set-Content -Path (Join-Path $manifestDir 'repos.yaml') -Value $manifestYaml

        # Build the gh shim. The function calls `gh auth status` (must
        # exit 0) and `gh repo list <Org> --limit 1000 --json ...`.
        $script:shimDir = Join-Path $script:tempRoot 'shim'
        New-Item -ItemType Directory -Path $script:shimDir -Force | Out-Null
        $payload = @'
[
  {"nameWithOwner":"ChannelAssist/Keystone","isArchived":false,"isPrivate":false,"defaultBranchRef":{"name":"master"}},
  {"nameWithOwner":"ChannelAssist/ca-foo","isArchived":false,"isPrivate":false,"defaultBranchRef":{"name":"main"}},
  {"nameWithOwner":"ChannelAssist/ca-new","isArchived":false,"isPrivate":false,"defaultBranchRef":{"name":"main"}},
  {"nameWithOwner":"ChannelAssist/cm-stale-archived","isArchived":true,"isPrivate":false,"defaultBranchRef":{"name":"main"}}
]
'@
        $payloadFile = Join-Path $script:shimDir 'gh-payload.json'
        Set-Content -Path $payloadFile -Value $payload
        if ($IsWindows) {
            $shimPath = Join-Path $script:shimDir 'gh.cmd'
            Set-Content -Path $shimPath -Value "@echo off`r`nif `"%1`"==`"auth`" exit /b 0`r`nif `"%1`"==`"repo`" type `"$payloadFile`" & exit /b 0`r`nexit /b 0"
        } else {
            $shimPath = Join-Path $script:shimDir 'gh'
            $shellShim = "#!/bin/bash`nif [ `"`$1`" = `"auth`" ]; then exit 0; fi`nif [ `"`$1`" = `"repo`" ] && [ `"`$2`" = `"list`" ]; then cat '$payloadFile'; exit 0; fi`nexit 0"
            Set-Content -Path $shimPath -Value $shellShim
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

    It 'computes missing/stale/archived buckets and exits 0 via JSON path' {
        $jsonOutFile = Join-Path $script:tempRoot 'drift.json'
        $rr = $script:repoRoot
        $tr = $script:tempRoot
        & pwsh -NoProfile -Command @"
. '$rr/lib/ui.ps1'
. '$rr/lib/yaml.ps1'
. '$rr/lib/journal.ps1'
. '$rr/commands/manifest-drift.ps1'
function Read-CABManifest {
    param([string]`$Path, [switch]`$Quiet)
    if (-not `$Quiet) { Write-Host 'NOISY-MANIFEST-READ' }
    return [pscustomobject]@{
        groups = @(
            [pscustomobject]@{
                name = 'docs'
                repos = @(
                    [pscustomobject]@{ repo = 'ChannelAssist/Keystone'; into = 'docs/keystone'; branch = 'master' }
                )
            },
            [pscustomobject]@{
                name = 'ca-platform'
                repos = @(
                    [pscustomobject]@{ repo = 'ChannelAssist/ca-foo'; into = 'ca-platform/ca-foo'; branch = 'main' }
                )
            },
            [pscustomobject]@{
                name = 'cm-product'
                repos = @(
                    [pscustomobject]@{ repo = 'ChannelAssist/cm-deleted'; into = 'cm-product/cm-deleted'; branch = 'main' },
                    [pscustomobject]@{ repo = 'ChannelAssist/cm-stale-archived'; into = 'cm-product/cm-stale-archived'; branch = 'main' }
                )
            }
        )
    }
}
`$ctx = @{ RepoRoot = '$tr' }
Invoke-CABCommandManifestDrift -Context `$ctx -Json | Out-Null
"@ > $jsonOutFile

        $report = Get-Content -Raw $jsonOutFile | ConvertFrom-Json
        $report.org_repo_count   | Should -Be 4
        $report.manifest_count   | Should -Be 4

        @($report.missing).Count | Should -Be 1
        ($report.missing | ForEach-Object { $_.slug }) | Should -Contain 'ChannelAssist/ca-new'
        $report.missing[0].suggested_group | Should -Be 'ca-platform'

        @($report.stale).Count   | Should -Be 1
        ($report.stale | ForEach-Object { $_.slug }) | Should -Contain 'ChannelAssist/cm-deleted'

        @($report.archived).Count | Should -Be 1
        ($report.archived | ForEach-Object { $_.slug }) | Should -Contain 'ChannelAssist/cm-stale-archived'

        $report.drift_total | Should -Be 3
    }

    It 'preserves a non-drift exit code when gh auth fails' {
        $stateDir = Join-Path $script:tempRoot 'state'
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

        $shimPath = if ($IsWindows) {
            Join-Path $script:shimDir 'gh.cmd'
        } else {
            Join-Path $script:shimDir 'gh'
        }
        if ($IsWindows) {
            Set-Content -Path $shimPath -Value "@echo off`r`nif `"%1`"==`"auth`" exit /b 1`r`nexit /b 0"
        } else {
            Set-Content -Path $shimPath -Value "#!/bin/bash`nif [ `"`$1`" = `"auth`" ]; then exit 1; fi`nexit 0"
            chmod +x $shimPath
        }

        $repoScript = Join-Path $script:repoRoot 'ca-bootstrap.ps1'
        $oldState = $env:CA_BOOTSTRAP_STATE
        try {
            $env:CA_BOOTSTRAP_STATE = $stateDir
            & pwsh -NoProfile -File $repoScript manifest-drift -NoColor | Out-Null
            $LASTEXITCODE | Should -Be 1
        } finally {
            $env:CA_BOOTSTRAP_STATE = $oldState
        }
    }
}
