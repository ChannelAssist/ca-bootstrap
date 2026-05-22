#requires -Version 7.0
# tests/lib/folders-yaml-grammar.tests.ps1 — `renamed_from:` field round-trips
# through Read-CABManifest. Guards against a parser regression breaking the
# new doctor folder-rename check (AB#40007).

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
}

Describe 'manifest/folders.yaml: renamed_from grammar' {
    BeforeEach {
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) "cab-folders-$(Get-Random).yaml"
    }
    AfterEach {
        if ($script:tmp -and (Test-Path $script:tmp)) { Remove-Item -Force $script:tmp }
    }

    It 'preserves renamed_from on round-trip' {
        @'
version: 1
root_name: ChannelAssistDev
folders:
  - path: ca-experiments
    description: Internal experiments
    optional: true
    renamed_from: experiments
  - path: ca-work-dirs
    description: Working directories for Claude / Cowork / scratch
'@ | Set-Content -Path $script:tmp -Encoding utf8

        $m = Read-CABManifest -Path $script:tmp -Quiet
        $exp = $m.folders | Where-Object { $_.path -eq 'ca-experiments' } | Select-Object -First 1
        $exp.renamed_from | Should -Be 'experiments'

        $work = $m.folders | Where-Object { $_.path -eq 'ca-work-dirs' } | Select-Object -First 1
        $work.path | Should -Be 'ca-work-dirs'
        # ca-work-dirs is required → absence of optional key reads as null/empty
        [bool]$work.optional | Should -Be $false
    }
}
