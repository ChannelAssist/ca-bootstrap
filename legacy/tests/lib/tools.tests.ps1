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

        It 'returns na for not-linux tools on linux hosts' -Skip:(-not $IsLinux) {
            $tool = @{
                id = 'claude-desktop'; name = 'Claude Desktop'; platform = 'not-linux'
                check = @{ paths = @{ macos = @('/Applications/Claude.app') } }
            }
            $r = Test-CABTool -Tool $tool
            $r.status | Should -Be 'na'
            $r.details | Should -Match 'Linux'
        }

        It 'does NOT return na for not-linux tools on non-linux hosts' -Skip:($IsLinux) {
            # The platform guard should be transparent on Windows/macOS — the
            # check.paths probe runs as if the platform key weren't present.
            $tool = @{
                id = 'claude-desktop'; name = 'Claude Desktop'; platform = 'not-linux'
                check = @{ paths = @{
                    windows = @('C:\definitely-not-here\claude.exe')
                    macos   = @('/definitely-not-here/Claude.app')
                } }
            }
            $r = Test-CABTool -Tool $tool
            $r.status | Should -Not -Be 'na'
        }
    }

    Context 'check.paths probe (GUI apps)' {
        It 'returns ok when at least one path exists' {
            $tmp = New-TemporaryFile
            try {
                $osKey = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
                $tool = @{
                    id = 'fake-gui'; name = 'Fake'
                    check = @{ paths = @{ $osKey = @($tmp.FullName) } }
                }
                $r = Test-CABTool -Tool $tool
                $r.status | Should -Be 'ok'
                $r.details | Should -Match ([regex]::Escape($tmp.FullName))
            } finally {
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        It 'returns fail when no listed path exists' {
            $osKey = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
            $tool = @{
                id = 'fake-gui'; name = 'Fake'
                check = @{ paths = @{ $osKey = @('/__definitely-not-here__/x') } }
            }
            $r = Test-CABTool -Tool $tool
            $r.status | Should -Be 'fail'
            $r.details | Should -Match 'Not installed'
        }

        It 'expands a leading ~ at probe time' {
            # Drop a marker file in $HOME and reference it via ~/ in the
            # manifest-style path string. If expansion happens correctly,
            # the probe finds it; if the literal string is used, it doesn't.
            $marker = Join-Path $HOME ".cab-test-marker-$([Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType File -Path $marker -Force | Out-Null
            try {
                $osKey = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
                $rel = "~/$(Split-Path $marker -Leaf)"
                $tool = @{
                    id = 'fake-gui'; name = 'Fake'
                    check = @{ paths = @{ $osKey = @($rel) } }
                }
                (Test-CABTool -Tool $tool).status | Should -Be 'ok'
            } finally {
                Remove-Item $marker -Force -ErrorAction SilentlyContinue
            }
        }

        It 'expands $env:VAR tokens at probe time' {
            # Set a sentinel env var to point at a temp directory, drop a
            # marker file there, and reference it via $env:CAB_TEST_DIR
            # in the manifest path. If safe-expansion handles env vars,
            # the probe finds the marker.
            $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) "cab-test-$([Guid]::NewGuid().ToString('N'))") -Force
            $marker = Join-Path $tmp.FullName 'sentinel.txt'
            New-Item -ItemType File -Path $marker | Out-Null
            $env:CAB_TEST_DIR = $tmp.FullName
            try {
                $osKey = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
                $tool = @{
                    id = 'fake-gui'; name = 'Fake'
                    check = @{ paths = @{ $osKey = @('$env:CAB_TEST_DIR/sentinel.txt') } }
                }
                (Test-CABTool -Tool $tool).status | Should -Be 'ok'
            } finally {
                Remove-Item $env:CAB_TEST_DIR -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item Env:CAB_TEST_DIR -ErrorAction SilentlyContinue
            }
        }

        It 'does NOT evaluate $(...) PowerShell subexpressions in path strings' {
            # Defense-in-depth: a malicious manifest can't trick the
            # detector into running arbitrary code via $(...). The path
            # should be treated as a literal string after env+tilde
            # expansion — $(Get-Date) etc. stays literal and Test-Path
            # fails to find it. (Compare with $ExecutionContext.InvokeCommand.ExpandString
            # which would evaluate the subexpression.)
            $osKey = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
            $tool = @{
                id = 'fake-gui'; name = 'Fake'
                check = @{ paths = @{ $osKey = @('/tmp/$(Get-Date -Format yyyy)/marker') } }
            }
            $r = Test-CABTool -Tool $tool
            $r.status | Should -Be 'fail'
            # The literal subexpression syntax should survive into the
            # 'Not installed' detail message — proves it wasn't evaluated.
            $r.details | Should -Match '\$\(Get-Date'
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

    Context 'end-to-end dispatch (gh shimmed)' {
        BeforeAll {
            # Shim gh by defining a function in global scope. PowerShell's
            # function table takes precedence over PATH, so `& gh ...` in
            # Install-CABTool hits this handler instead of the real CLI.
            # Tracks invocations on $script:ghCalls so each It can assert
            # which subcommand actually ran.
            $script:ghListOutput = ''
            $script:ghCalls      = @()
            function global:gh {
                $script:ghCalls += @{ argv = ($args -join ' ') }
                $joined = ($args -join ' ')
                if ($joined -match '^extension list') {
                    Write-Output $script:ghListOutput
                    $global:LASTEXITCODE = 0
                    return
                }
                $global:LASTEXITCODE = 0
            }
        }
        AfterAll {
            Remove-Item -Path Function:gh -Force -ErrorAction SilentlyContinue
        }
        BeforeEach {
            $script:ghCalls      = @()
            $script:ghListOutput = ''
        }

        It 'invokes upgrade with the local name when the target is already installed' {
            $script:ghListOutput = @(
                "gh copilot`tgithub/gh-copilot`tv1.0.0"
                "gh dash`tdlvhdr/gh-dash`tv3.5.2"
            ) -join "`n"
            $tool = @{
                id = 'gh-copilot'; name = 'X'
                install = @{
                    windows = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    macos   = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    linux   = @{ any = @{ type = 'gh-extension'; id = 'github/gh-copilot' } }
                }
            }
            $r = Install-CABTool -Tool $tool -Context @{}
            $r.ok | Should -BeTrue
            $upgrades = @($script:ghCalls | Where-Object { $_.argv -match '^extension upgrade' })
            $upgrades.Count | Should -Be 1
            # local name from column 1's "gh <name>" should be 'copilot'.
            $upgrades[0].argv | Should -Match 'extension upgrade copilot'
            # Should NOT have called extension install.
            @($script:ghCalls | Where-Object { $_.argv -match '^extension install' }).Count | Should -Be 0
        }

        It 'invokes install with the full owner/repo when the target is missing' {
            $script:ghListOutput = "gh dash`tdlvhdr/gh-dash`tv3.5.2"
            $tool = @{
                id = 'gh-copilot'; name = 'X'
                install = @{
                    windows = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    macos   = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    linux   = @{ any = @{ type = 'gh-extension'; id = 'github/gh-copilot' } }
                }
            }
            $r = Install-CABTool -Tool $tool -Context @{}
            $r.ok | Should -BeTrue
            $installs = @($script:ghCalls | Where-Object { $_.argv -match '^extension install' })
            $installs.Count | Should -Be 1
            $installs[0].argv | Should -Match 'extension install github/gh-copilot'
            @($script:ghCalls | Where-Object { $_.argv -match '^extension upgrade' }).Count | Should -Be 0
        }

        It 'does not match a forked extension whose short name collides with the target' {
            # Two extensions installed: a different fork that happens to
            # share the "gh-copilot" short name, and our actual target.
            # Exact column-2 match must pick our row, not the fork.
            $script:ghListOutput = @(
                "gh fakecopilot`tsome-fork/gh-copilot-helper`tv2.0.0"
                "gh copilot`tgithub/gh-copilot`tv1.0.0"
            ) -join "`n"
            $tool = @{
                id = 'gh-copilot'; name = 'X'
                install = @{
                    windows = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    macos   = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    linux   = @{ any = @{ type = 'gh-extension'; id = 'github/gh-copilot' } }
                }
            }
            Install-CABTool -Tool $tool -Context @{} | Out-Null
            $upgrades = @($script:ghCalls | Where-Object { $_.argv -match '^extension upgrade' })
            $upgrades.Count | Should -Be 1
            # Must use the local name from OUR matched row (`copilot`),
            # not from the fork's row (`fakecopilot`).
            $upgrades[0].argv | Should -Match 'extension upgrade copilot$'
            $upgrades[0].argv | Should -Not -Match 'fakecopilot'
        }

        It 'treats a substring collision (different owner/repo) as missing — installs, not upgrades' {
            # The fork has a similar short name but a different owner/repo.
            # The substring "gh-copilot" appears in the fork's repo name
            # but column-2 exact-match must reject it.
            $script:ghListOutput = "gh fakecopilot`tsome-fork/gh-copilot-helper`tv2.0.0"
            $tool = @{
                id = 'gh-copilot'; name = 'X'
                install = @{
                    windows = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    macos   = @{ type = 'gh-extension'; id = 'github/gh-copilot' }
                    linux   = @{ any = @{ type = 'gh-extension'; id = 'github/gh-copilot' } }
                }
            }
            Install-CABTool -Tool $tool -Context @{} | Out-Null
            @($script:ghCalls | Where-Object { $_.argv -match '^extension install' }).Count | Should -Be 1
            @($script:ghCalls | Where-Object { $_.argv -match '^extension upgrade' }).Count | Should -Be 0
        }
    }
}

Describe 'Install-CABTool — installer presence guards' {
    # Pre-dispatch checks added in 1d2e50a so a missing winget/npm
    # produces a friendly ok=$false with remediation instead of letting
    # `& winget`/`& npm` throw a PowerShell ObjectNotFound exception.
    # These tests pin that contract.

    Context 'winget branch' {
        It 'returns ok=$false with remediation when winget is not on PATH' {
            # Force the windows install entry and stub out winget presence.
            Mock Get-CABOSFamily { 'windows' }
            Mock Get-Command -ParameterFilter { $Name -eq 'winget' } -MockWith { $null }
            $tool = @{
                id = 'fake-winget-tool'
                name = 'Fake'
                install = @{ windows = @{ type = 'winget'; id = 'Fake.Tool' } }
            }
            $r = Install-CABTool -Tool $tool -Context @{}
            $r.ok | Should -BeFalse
            $r.details | Should -Match 'winget not on PATH'
            # Remediation should point at the canonical fix.
            $r.details | Should -Match 'aka.ms/getwinget|App Installer'
        }
    }

    Context 'npm branch' {
        It 'returns ok=$false with remediation when npm is not on PATH' {
            Mock Get-CABOSFamily { 'windows' }
            Mock Get-Command -ParameterFilter { $Name -eq 'npm' } -MockWith { $null }
            $tool = @{
                id = 'fake-npm-tool'
                name = 'Fake'
                install = @{ windows = @{ type = 'npm'; id = '@org/fake'; global = $true } }
            }
            $r = Install-CABTool -Tool $tool -Context @{}
            $r.ok | Should -BeFalse
            $r.details | Should -Match 'npm not on PATH'
            # Remediation should point at the Node.js install path.
            $r.details | Should -Match 'Node\.js|OpenJS\.NodeJS'
        }
    }
}
