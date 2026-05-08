#requires -Version 7.0
# tests/wizard/setup-end-to-end.tests.ps1
#
# Layer 3: spawn the wizard as a subprocess and assert the resulting
# on-disk state. This is the test that catches stream-handling bugs,
# parameter-binding bugs, and OS-specific subprocess gotchas.
#
# Hermetic via the CA_BOOTSTRAP_TEST_MODE seam (see TEST_PLAN.md §8.1):
#   TEST_GH_USER → step 30 returns "logged in as <user>" without gh
#   TEST_TOOLS_OK = "*" → step 20 trusts the manifest, no tool checks

BeforeAll {
    $script:repoRoot   = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:bootstrap  = Join-Path $script:repoRoot 'ca-bootstrap.ps1'
    $script:answers    = Join-Path $script:repoRoot 'tests/fixtures/answers/hermetic.yaml'
}

Describe 'Wizard end-to-end (Layer 3)' {
    BeforeEach {
        $script:tempRoot   = Join-Path ([System.IO.Path]::GetTempPath()) "cab-w-$(Get-Random)"
        $script:tempState  = Join-Path $script:tempRoot 'state'
        $script:tempWs     = Join-Path $script:tempRoot 'ws'
        [void](New-Item -ItemType Directory -Path $script:tempRoot -Force)
    }
    AfterEach {
        if ($script:tempRoot -and (Test-Path $script:tempRoot)) {
            Remove-Item -Recurse -Force $script:tempRoot -ErrorAction SilentlyContinue
        }
    }

    It 'setup -Unattended completes with exit 0 and creates expected on-disk state' {
        $envBlock = @"
`$env:CA_BOOTSTRAP_STATE = '$script:tempState'
`$env:CA_BOOTSTRAP_WORKSPACE = '$script:tempWs'
`$env:CA_BOOTSTRAP_TEST_MODE = '1'
`$env:CA_BOOTSTRAP_TEST_GH_USER = 'fake-user'
& '$script:bootstrap' setup -Unattended -ConfigFile '$script:answers'
"@
        $output = & pwsh -NoLogo -NoProfile -Command $envBlock 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because "wizard exited 0; output was:`n$output"

        Test-Path $script:tempWs -PathType Container | Should -BeTrue -Because 'workspace must be created'
        foreach ($sub in 'ca-tools','ca-docs','ca-platform','cm-product') {
            Test-Path (Join-Path $script:tempWs $sub) -PathType Container | Should -BeTrue -Because "subfolder $sub must be created"
        }

        $journal = Join-Path $script:tempState 'journal.yaml'
        Test-Path $journal | Should -BeTrue
        Import-Module powershell-yaml -DisableNameChecking
        $parsed = ConvertFrom-Yaml (Get-Content -Raw $journal)
        $parsed.schema_version | Should -Be 1
        @($parsed.sessions).Count | Should -BeGreaterThan 0
    }

    It 'setup -Unattended is idempotent across multiple runs' {
        $envBlock = @"
`$env:CA_BOOTSTRAP_STATE = '$script:tempState'
`$env:CA_BOOTSTRAP_WORKSPACE = '$script:tempWs'
`$env:CA_BOOTSTRAP_TEST_MODE = '1'
`$env:CA_BOOTSTRAP_TEST_GH_USER = 'fake-user'
& '$script:bootstrap' setup -Unattended -ConfigFile '$script:answers'
"@
        & pwsh -NoLogo -NoProfile -Command $envBlock 2>&1 | Out-Null
        $first = $LASTEXITCODE
        & pwsh -NoLogo -NoProfile -Command $envBlock 2>&1 | Out-Null
        $second = $LASTEXITCODE

        $first  | Should -Be 0
        $second | Should -Be 0 -Because 're-running setup must succeed without re-doing already-completed work'
    }
}
