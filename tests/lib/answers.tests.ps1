#requires -Version 7.0
# tests/lib/answers.tests.ps1 — Convert-CABAnswersToFlat unit tests.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/answers.ps1')
}

Describe 'Convert-CABAnswersToFlat' {
    It 'always sets welcome.continue to true' {
        $a = @{}
        $f = Convert-CABAnswersToFlat -Answers $a
        $f['welcome.continue'] | Should -BeTrue
    }

    It 'maps prerequisites.install_missing into prereqs.install_choice' {
        $f = Convert-CABAnswersToFlat -Answers @{ prerequisites = @{ install_missing = $true } }
        $f['prereqs.install_choice'] | Should -Be 'Y'

        $f = Convert-CABAnswersToFlat -Answers @{ prerequisites = @{ install_missing = $false } }
        $f['prereqs.install_choice'] | Should -Be 'n'
    }

    It 'expands prerequisites.selections into per-tool keys' {
        $f = Convert-CABAnswersToFlat -Answers @{
            prerequisites = @{
                selections = @{ git = 'install'; docker = 'skip' }
            }
        }
        $f['prereqs.install.git']    | Should -BeTrue
        $f['prereqs.install.docker'] | Should -BeFalse
    }

    It 'maps clone.groups all/none into Y/n' {
        $f = Convert-CABAnswersToFlat -Answers @{
            clone = @{ groups = @{ 'docs' = 'all'; 'cm-product' = 'none'; 'ado-legacy' = 'skip' } }
        }
        $f['repos.group.docs']        | Should -Be 'Y'
        $f['repos.group.cm-product']  | Should -Be 'n'
        $f['repos.group.ado-legacy']  | Should -Be 'n'
    }

    It 'sets per-repo overrides from clone.exclude' {
        $f = Convert-CABAnswersToFlat -Answers @{
            clone = @{ exclude = @('ChannelAssist/channel-manager') }
        }
        $f['repos.repo.ChannelAssist/channel-manager'] | Should -BeFalse
    }

    It 'plumbs git_identity name/email through env vars' {
        $env:CA_BOOTSTRAP_GIT_NAME = $null
        $env:CA_BOOTSTRAP_GIT_EMAIL = $null
        Convert-CABAnswersToFlat -Answers @{
            git_identity = @{ configure = $true; name = 'Alice'; email = 'a@x.com' }
        } | Out-Null
        $env:CA_BOOTSTRAP_GIT_NAME  | Should -Be 'Alice'
        $env:CA_BOOTSTRAP_GIT_EMAIL | Should -Be 'a@x.com'
        Remove-Item Env:CA_BOOTSTRAP_GIT_NAME, Env:CA_BOOTSTRAP_GIT_EMAIL -ErrorAction SilentlyContinue
    }
}
