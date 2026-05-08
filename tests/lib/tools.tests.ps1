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

Describe 'Install-CABTool — gh-extension dispatch' {
    BeforeAll {
        # Build a tool entry covering all three OSes so the test runs on
        # whatever Get-CABOSFamily reports for the host.
        function script:New-GhExtTool {
            param([string]$Id, [string]$ExtId)
            @{
                id      = $Id
                name    = $Id
                install = @{
                    windows = @{ type = 'gh-extension'; id = $ExtId }
                    macos   = @{ type = 'gh-extension'; id = $ExtId }
                    linux   = @{ any = @{ type = 'gh-extension'; id = $ExtId } }
                }
            }
        }
    }

    Context 'WhatIfMode short-circuit' {
        It 'returns ok=true with WhatIf details and never tries to invoke gh' {
            $tool = New-GhExtTool -Id 'gh-copilot' -ExtId 'github/gh-copilot'
            $r = Install-CABTool -Tool $tool -Context @{ WhatIfMode = $true }
            $r.ok | Should -BeTrue
            $r.details | Should -Match 'WhatIf'
        }
    }

    Context 'when gh is missing from PATH' {
        It 'returns ok=false with a helpful detail (no subprocess attempted)' {
            # Fake gh-as-missing without altering the real PATH. Pester's
            # Mock can stub Get-Command; the gh-extension branch checks
            # `Get-Command 'gh' -ErrorAction SilentlyContinue` and bails
            # when null is returned.
            Mock Get-Command -ParameterFilter { $Name -eq 'gh' } -MockWith { $null }
            $tool = New-GhExtTool -Id 'gh-copilot' -ExtId 'github/gh-copilot'
            $r = Install-CABTool -Tool $tool -Context @{}
            $r.ok | Should -BeFalse
            $r.details | Should -Match 'gh CLI not on PATH'
        }
    }

    Context 'matching against gh extension list' {
        It 'matches owner/repo exactly — substring collisions do not trigger upgrade' {
            # Smoke test the match logic via a string-only fixture so we
            # don't need to spin up a real gh CLI. The same column-2
            # exact-match the install handler does.
            $listOutput = @(
                "gh fakecopilot`tsome-fork/gh-copilot-helper`tv2.0.0"
                "gh dash`tdlvhdr/gh-dash`tv3.5.2"
            ) -join "`n"
            $target = 'github/gh-copilot'
            $alreadyInstalled = $false
            foreach ($row in @($listOutput -split "`r?`n")) {
                $cols = $row -split "`t"
                if (@($cols).Count -ge 2 -and $cols[1].Trim() -ieq $target) {
                    $alreadyInstalled = $true; break
                }
            }
            $alreadyInstalled | Should -BeFalse
        }

        It 'matches owner/repo exactly — exact match triggers upgrade path' {
            $listOutput = @(
                "gh copilot`tgithub/gh-copilot`tv1.0.0"
                "gh fakecopilot`tsome-fork/gh-copilot-helper`tv2.0.0"
            ) -join "`n"
            $target = 'github/gh-copilot'
            $alreadyInstalled = $false
            foreach ($row in @($listOutput -split "`r?`n")) {
                $cols = $row -split "`t"
                if (@($cols).Count -ge 2 -and $cols[1].Trim() -ieq $target) {
                    $alreadyInstalled = $true; break
                }
            }
            $alreadyInstalled | Should -BeTrue
        }
    }
}
