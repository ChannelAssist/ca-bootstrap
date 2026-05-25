#requires -Version 7.0
# tests/regression/v1.9.x-continue-on-tool-failure.tests.ps1
#
# Behavior under test (introduced in AB#39916 / PR #73): when a tool's
# install fails inside step 20-prereqs, the wizard previously aborted
# with a rollback offer if the tool was 'required'. The continue-on-
# failure path now downgrades required-tool install failures to
# status='warn' so the orchestrator continues into gh-auth / folders /
# clones, and the failed tool accumulates into $Context.FailedTools
# for the end-of-run summary.
#
# Properties:
#   1. Step 20 returns status='warn' (NOT 'fail') when a required tool's
#      install fails — i.e., the orchestrator will not see a fail status.
#   2. $Context.FailedTools is populated with {id, required, details} for
#      each failed install.
#   3. The required-flag on the FailedTools entry is true for tools in
#      the manifest's `required` list, false for `optional`.
#   4. The all-clean path (no install attempts needed) returns 'ok' and
#      does not touch FailedTools.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
    . (Join-Path $repoRoot 'steps/20-prereqs.ps1')
}

Describe 'Step 20 continue-on-failure (regression AB#39916)' {
    BeforeEach {
        # Unattended + "Yes, install all" so step 20 enters the install
        # loop without needing a real Read-Host prompt.
        Set-CABPromptMode -Unattended $true -Answers @{
            'prereqs.install_choice' = 'Y'
        }
        # Suppress real journal I/O so the test doesn't touch disk.
        Mock Add-CABJournalEntry { } -ModuleName $null
        # Test-CABTool is called for the post-install re-check; with a
        # failed install it shouldn't be called, but mock it anyway so
        # the test is hermetic if behavior changes.
        Mock Test-CABTool { @{ status = 'fail'; details = 'mocked' } }
    }

    AfterEach {
        Set-CABPromptMode -Unattended $false -Answers @{}
    }

    It 'returns status=warn (not fail) when a required tool install fails' {
        # Stage `git` as missing-and-required; mock the install to fail.
        Mock Get-CABToolReport {
            @(
                @{ id = 'git'; name = 'Git'; status = 'fail'; is_required = $true; details = 'Not installed.' }
            )
        }
        Mock Install-CABTool { @{ ok = $false; details = 'simulated winget exit 1' } }

        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $ctx = @{
            RepoRoot    = $repoRoot
            TotalSteps  = 9
            StepOrdinal = 4
        }
        $result = Invoke-CABStep20 -Context $ctx

        $result.status | Should -Be 'warn'
        # Old behavior would have returned 'fail' here — guard against
        # regression by asserting it never reaches the fail path.
        $result.status | Should -Not -Be 'fail'
        $result.details | Should -Match 'Required failures|failed'
    }

    It 'populates Context.FailedTools with the failed entry' {
        Mock Get-CABToolReport {
            @(
                @{ id = 'git'; name = 'Git'; status = 'fail'; is_required = $true; details = 'Not installed.' }
            )
        }
        Mock Install-CABTool { @{ ok = $false; details = 'simulated winget exit 1638' } }

        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $ctx = @{
            RepoRoot    = $repoRoot
            TotalSteps  = 9
            StepOrdinal = 4
        }
        $null = Invoke-CABStep20 -Context $ctx

        @($ctx.FailedTools).Count | Should -BeGreaterThan 0
        $entry = @($ctx.FailedTools) | Where-Object { $_.id -eq 'git' } | Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $entry.required | Should -BeTrue
        $entry.details | Should -Match 'simulated'
    }

    It 'still returns warn for an optional-tool failure (no behavior change for optional path)' {
        # `wsl` is optional in the manifest. Stage it as missing + fail.
        Mock Get-CABToolReport {
            @(
                @{ id = 'wsl'; name = 'WSL2'; status = 'fail'; is_required = $false; details = 'Not installed.' }
            )
        }
        Mock Install-CABTool { @{ ok = $false; details = 'simulated wsl install failure' } }

        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $ctx = @{
            RepoRoot    = $repoRoot
            TotalSteps  = 9
            StepOrdinal = 4
        }
        $result = Invoke-CABStep20 -Context $ctx

        $result.status | Should -Be 'warn'
        $entry = @($ctx.FailedTools) | Where-Object { $_.id -eq 'wsl' } | Select-Object -First 1
        $entry | Should -Not -BeNullOrEmpty
        $entry.required | Should -BeFalse
    }

    It 'returns ok and leaves FailedTools untouched when nothing is missing' {
        Mock Get-CABToolReport {
            @(
                @{ id = 'git'; name = 'Git'; status = 'ok'; is_required = $true; details = 'Installed.' }
            )
        }
        # Install-CABTool must NOT be called on this path; we mock it to
        # throw so a regression that calls it would fail the test loudly.
        Mock Install-CABTool { throw 'Install-CABTool should not have been called on the all-clean path.' }

        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $ctx = @{
            RepoRoot    = $repoRoot
            TotalSteps  = 9
            StepOrdinal = 4
        }
        $result = Invoke-CABStep20 -Context $ctx

        $result.status | Should -Be 'ok'
        # FailedTools is initialized in the install-loop branch (which
        # we don't enter), so it should not exist on the all-clean path.
        $ctx.ContainsKey('FailedTools') | Should -BeFalse
    }
}
