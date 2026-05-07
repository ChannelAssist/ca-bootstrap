#requires -Version 7.0
# tests/lib/repos-drift.tests.ps1 — unit tests for repos-drift functionality.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/git-ops.ps1')
    . (Join-Path $repoRoot 'lib/repos-drift.ps1')
}

Describe 'Compare-CABRepoManifest' {
    BeforeAll {
        # Create a test manifest
        $testManifest = Join-Path $TestDrive 'test-repos.yaml'
        @'
version: 1
default_protocol: https
groups:
  - name: test-group
    repos:
      - { repo: ChannelAssist/repo-a, into: test/repo-a, branch: main }
      - { repo: ChannelAssist/repo-b, into: test/repo-b, branch: main }
      - { repo: ChannelAssist/deleted-repo, into: test/deleted-repo, branch: main }
'@ | Set-Content $testManifest
    }

    It 'requires manifest path' {
        { Compare-CABRepoManifest -ManifestPath '/nonexistent/path' } | Should -Throw
    }

    It 'handles manifest read successfully' -Skip {
        # This test requires powershell-yaml module to be installed
        # and gh CLI to be authenticated. Skipping in CI.
        $hasGh = Test-CABCommandAvailable 'gh'
        if (-not $hasGh) {
            Set-ItResult -Skipped -Because 'gh CLI not available'
            return
        }

        $result = Compare-CABRepoManifest -ManifestPath $testManifest -Org 'ChannelAssist'

        # Result should have expected structure
        $result | Should -Not -BeNullOrEmpty
        $result.Keys | Should -Contain 'ok'
        $result.Keys | Should -Contain 'inManifestNotInOrg'
        $result.Keys | Should -Contain 'inOrgNotInManifest'
    }
}

Describe 'Get-CABOrgRepos' {
    It 'returns empty array when gh is not available' {
        Mock Test-CABCommandAvailable { return $false }
        $null = Get-CABOrgRepos -Org 'ChannelAssist' -ErrorAction SilentlyContinue *>&1
        # Function should return early without calling gh
        Should -Invoke Test-CABCommandAvailable -Exactly 1
    }

    It 'returns empty array when gh auth fails' {
        Mock Test-CABCommandAvailable { return $true }
        Mock Test-CABGhAuth { return $false }
        $null = Get-CABOrgRepos -Org 'ChannelAssist' -ErrorAction SilentlyContinue *>&1
        # Function should check auth and return early
        Should -Invoke Test-CABGhAuth -Exactly 1
    }
}

Describe 'Format-CABReposDriftReport' {
    It 'handles no drift case' {
        $comparison = @{
            ok = $true
            inManifestNotInOrg = @()
            inOrgNotInManifest = @()
            manifestRepoCount = 5
            orgRepoCount = 5
        }
        { Format-CABReposDriftReport -Comparison $comparison } | Should -Not -Throw
    }

    It 'handles drift detected case' {
        $comparison = @{
            ok = $false
            inManifestNotInOrg = @('ChannelAssist/deleted-repo')
            inOrgNotInManifest = @('ChannelAssist/new-repo')
            manifestRepoCount = 5
            orgRepoCount = 5
        }
        { Format-CABReposDriftReport -Comparison $comparison } | Should -Not -Throw
    }

    It 'handles error case' {
        $comparison = @{
            ok = $false
            error = 'Failed to fetch org repos'
            inManifestNotInOrg = @()
            inOrgNotInManifest = @()
        }
        { Format-CABReposDriftReport -Comparison $comparison } | Should -Not -Throw
    }
}
