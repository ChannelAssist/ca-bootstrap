#requires -Version 7.0
# tests/lib/manifest-consistency.tests.ps1 -- guards the implicit
# contract between manifest/repos.yaml and manifest/folders.yaml.
#
# Background: step 50 only creates folders declared in folders.yaml, and
# step 80's Get-CABClonedReposFromWorkspace only walks them when building
# the VS Code multi-root workspace file. So a repos.yaml `into:` prefix
# that's absent from folders.yaml will silently drop the repo from the
# generated workspace (and break tests that exercise the full setup
# wizard against a hermetic fixture).
#
# This test asserts the contract: every distinct top-level prefix used in
# any repos.yaml `into:` field appears as a `path:` in folders.yaml.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')

    $script:repos   = Read-CABManifest -Path (Join-Path $script:repoRoot 'manifest/repos.yaml')   -Quiet
    $script:folders = Read-CABManifest -Path (Join-Path $script:repoRoot 'manifest/folders.yaml') -Quiet
}

Describe 'manifest/repos.yaml + manifest/folders.yaml consistency' {
    It 'every into: prefix in repos.yaml is declared in folders.yaml' {
        $declared = @($script:folders.folders | ForEach-Object { [string]$_.path })

        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($group in $script:repos.groups) {
            foreach ($repo in $group.repos) {
                if (-not $repo.into) {
                    throw "Repo $($repo.repo) in group '$($group.name)' has no 'into:' field."
                }
                $prefix = ($repo.into -split '[\\/]', 2)[0]
                if ($declared -notcontains $prefix) {
                    $missing.Add("$($repo.repo) into=$($repo.into) (prefix '$prefix' not in folders.yaml)")
                }
            }
        }

        $missing | Should -BeNullOrEmpty -Because (
            "every repos.yaml 'into:' prefix must exist as a path in folders.yaml so step 50 creates it and step 80 discovers it. Missing:`n  " +
            ($missing -join "`n  ")
        )
    }

    It 'every folders.yaml entry has a non-empty path' {
        foreach ($f in $script:folders.folders) {
            ([string]$f.path) | Should -Not -BeNullOrEmpty
        }
    }
}
