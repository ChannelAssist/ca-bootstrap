#requires -Version 7.0
# tests/lib/tools.tests.ps1 — Pester tests for lib/tools.ps1.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
}

Describe 'Compare-CABVersion' {
    It 'compares strict semver correctly' {
        Compare-CABVersion -Found '20.11.0' -Required '20.10.0' | Should -BeTrue
        Compare-CABVersion -Found '20.10.0' -Required '20.11.0' | Should -BeFalse
        Compare-CABVersion -Found '20.10.0' -Required '20.10.0' | Should -BeTrue
    }

    It 'normalizes a 1-segment version against a 3-segment requirement' {
        Compare-CABVersion -Found '20'      -Required '20.0.0' | Should -BeTrue
        Compare-CABVersion -Found '21'      -Required '20.0.0' | Should -BeTrue
        Compare-CABVersion -Found '19'      -Required '20.0.0' | Should -BeFalse
    }

    It 'strips a v prefix and pre-release suffix' {
        Compare-CABVersion -Found 'v20.11.0'    -Required '20'        | Should -BeTrue
        Compare-CABVersion -Found '20.11.0-rc1' -Required '20.11.0'   | Should -BeTrue
    }
}

Describe 'Test-CABTool' {
    Context 'platform restriction' {
        It 'returns na for windows-only tools on non-windows hosts' -Skip:($IsWindows) {
            $tool = @{
                id = 'wsl'; name = 'WSL'; platform = 'windows-only'
                check = @{ cmd = 'wsl --version' }
            }
            $r = Test-CABTool -Tool $tool
            $r.status | Should -Be 'na'
        }
    }

    Context 'meta-tools without check.cmd' {
        It 'returns ok when the tool has a requires field' {
            $tool = @{ id = 'vscode-extensions'; name = 'X'; requires = @('vscode') }
            (Test-CABTool -Tool $tool).status | Should -Be 'ok'
        }
        It 'returns error when there is no check and no requires' {
            $tool = @{ id = 'broken'; name = 'X' }
            (Test-CABTool -Tool $tool).status | Should -Be 'error'
        }
    }
}
