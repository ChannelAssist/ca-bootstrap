#requires -Version 7.0
# tests/wizard/step-15-platform-check.tests.ps1 — Pester unit tests for
# the Windows pre-flight step introduced under AB#39916 (PR #73).
#
# The probes inside step 15 each query real Windows surfaces
# (winget, ExecPolicy, Defender, %TEMP%, MSI cache). These tests
# mock each probe function so the step contract can be exercised on
# any host without depending on a real Windows install. They cover:
#
#   1. Non-Windows host  → status='skip', no PlatformReadiness written.
#   2. Windows + all ok  → status='ok', Context.PlatformReadiness populated.
#   3. Windows + warns   → status='warn', no proceed prompt fires.
#   4. Windows + fails,
#      user proceeds     → status='warn', continues setup.
#   5. Windows + fails,
#      user declines     → status='quit'.
#
# These pin the contract Copilot called out: "non-Windows no-op path,
# Windows path that always returns warn/ok/quit but never fail, and
# the contract that it populates Context.PlatformReadiness."

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
    . (Join-Path $repoRoot 'steps/15-platform-check.ps1')

    # Helper: builds an 8-probe mock set with the given statuses. Order
    # matches the probe array in Invoke-CABStep15; missing/unset entries
    # default to 'ok'. Keeps the per-test setup tight.
    function Set-CABMockProbes {
        param([hashtable]$Statuses = @{})
        $defaults = @{
            'winget'    = 'ok'
            'npm'       = 'ok'
            'execpol'   = 'ok'
            'elevation' = 'ok'
            'sources'   = 'ok'
            'temp'      = 'ok'
            'msi'       = 'ok'
            'defender'  = 'ok'
        }
        foreach ($k in $Statuses.Keys) { $defaults[$k] = $Statuses[$k] }
        Mock Test-CABWingetPresent   { @{ status = $defaults['winget'];    name = 'winget on PATH';            details = ''; remediation = 'fix winget' } }.GetNewClosure()
        Mock Test-CABNpmPresent      { @{ status = $defaults['npm'];       name = 'npm on PATH';               details = ''; remediation = '' } }.GetNewClosure() -ParameterFilter { $true }
        Mock Test-CABExecutionPolicy { @{ status = $defaults['execpol'];   name = 'PowerShell ExecutionPolicy'; details = ''; remediation = '' } }.GetNewClosure()
        Mock Test-CABElevation       { @{ status = $defaults['elevation']; name = 'Elevation';                 details = ''; remediation = '' } }.GetNewClosure()
        Mock Test-CABWingetSource    { @{ status = $defaults['sources'];   name = 'winget sources';            details = ''; remediation = '' } }.GetNewClosure()
        Mock Test-CABTempWritable    { @{ status = $defaults['temp'];      name = '%TEMP% writable';           details = ''; remediation = '' } }.GetNewClosure()
        Mock Test-CABMsiCache        { @{ status = $defaults['msi'];       name = 'MSI cache directory';       details = ''; remediation = '' } }.GetNewClosure()
        Mock Test-CABDefender        { @{ status = $defaults['defender'];  name = 'Defender real-time scan';   details = ''; remediation = '' } }.GetNewClosure()
    }
}

Describe 'Invoke-CABStep15 — non-Windows host' {
    It 'returns status=skip and does not populate PlatformReadiness' {
        Mock Get-CABOSFamily { 'macos' }
        $ctx = @{ TotalSteps = 9; StepOrdinal = 2 }
        $r = Invoke-CABStep15 -Context $ctx
        $r.status | Should -Be 'skip'
        $r.details | Should -Match 'Windows'
        # Non-Windows path bails before writing readiness data.
        $ctx.ContainsKey('PlatformReadiness') | Should -BeFalse
    }
}

Describe 'Invoke-CABStep15 — Windows, all probes ok' {
    It 'returns status=ok and populates Context.PlatformReadiness with all 8 probes' {
        Mock Get-CABOSFamily { 'windows' }
        Set-CABMockProbes

        $ctx = @{ TotalSteps = 9; StepOrdinal = 2 }
        $r = Invoke-CABStep15 -Context $ctx

        $r.status | Should -Be 'ok'
        $ctx.PlatformReadiness | Should -Not -BeNullOrEmpty
        @($ctx.PlatformReadiness.probes).Count | Should -Be 8
        @($ctx.PlatformReadiness.fails).Count  | Should -Be 0
        @($ctx.PlatformReadiness.warns).Count  | Should -Be 0
    }
}

Describe 'Invoke-CABStep15 — Windows, advisory warns only' {
    It 'returns status=warn without prompting and records warn in PlatformReadiness' {
        Mock Get-CABOSFamily { 'windows' }
        Set-CABMockProbes -Statuses @{ 'elevation' = 'warn'; 'defender' = 'warn' }

        $ctx = @{ TotalSteps = 9; StepOrdinal = 2 }
        $r = Invoke-CABStep15 -Context $ctx

        $r.status | Should -Be 'warn'
        $r.details | Should -Match 'advisory|none blocking'
        @($ctx.PlatformReadiness.warns).Count | Should -Be 2
        @($ctx.PlatformReadiness.fails).Count | Should -Be 0
    }
}

Describe 'Invoke-CABStep15 — Windows, blocking fail with user proceed' {
    It 'returns status=warn (user opted to continue past blocking issue)' {
        Mock Get-CABOSFamily { 'windows' }
        Set-CABMockProbes -Statuses @{ 'winget' = 'fail' }
        # Unattended + yes answers the proceed-with-fails prompt.
        Set-CABPromptMode -Unattended $true -Answers @{
            'platform-check.proceed_with_fails' = 'yes'
        }
        try {
            $ctx = @{ TotalSteps = 9; StepOrdinal = 2 }
            $r = Invoke-CABStep15 -Context $ctx

            $r.status | Should -Be 'warn'
            $r.details | Should -Match 'opted to continue|blocking'
            @($ctx.PlatformReadiness.fails).Count | Should -Be 1
        } finally {
            Set-CABPromptMode -Unattended $false -Answers @{}
        }
    }
}

Describe 'Invoke-CABStep15 — Windows, blocking fail with user decline' {
    It 'returns status=quit when the user declines to proceed past a blocking issue' {
        Mock Get-CABOSFamily { 'windows' }
        Set-CABMockProbes -Statuses @{ 'winget' = 'fail' }
        Set-CABPromptMode -Unattended $true -Answers @{
            'platform-check.proceed_with_fails' = 'no'
        }
        try {
            $ctx = @{ TotalSteps = 9; StepOrdinal = 2 }
            $r = Invoke-CABStep15 -Context $ctx

            $r.status | Should -Be 'quit'
            $r.details | Should -Match 'declined|blocking'
        } finally {
            Set-CABPromptMode -Unattended $false -Answers @{}
        }
    }
}
