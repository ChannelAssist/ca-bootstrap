#requires -Version 7.0
# tests/lib/prompts-eof.tests.ps1 — regression test for the curl|bash bug.
#
# When ca-bootstrap was launched via the curl-pipe one-liner without
# /dev/tty re-attach, `Read-Host` returned $null on every prompt and
# Read-CABChoice crashed with "You cannot call a method on a null-valued
# expression" because of the `(Read-Host).Trim()` chain. Read-CABConfirm
# silently auto-defaulted (which is its own user-experience problem —
# the user thought they were consenting). This test covers both code
# paths under a stdin-at-EOF condition.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    Set-CABPromptMode -Unattended $false -Answers @{}
}

Describe 'Read-CABChoice handles stdin-at-EOF safely' {
    It 'returns the Default key when Read-Host returns null and a default exists' {
        Mock -CommandName Read-Host -MockWith { return $null }
        $r = Read-CABChoice `
            -Question 'Pick' `
            -Options @(@{ Key = 'a'; Label = 'A' }, @{ Key = 'b'; Label = 'B' }) `
            -Default 'a'
        $r | Should -Be 'a'
    }

    It 'throws cleanly (no method-on-null) when no default exists and stdin is EOF' {
        Mock -CommandName Read-Host -MockWith { return $null }
        {
            Read-CABChoice `
                -Question 'Pick' `
                -Options @(@{ Key = 'a'; Label = 'A' })
        } | Should -Throw '*Interactive prompt requested but stdin is at EOF*'
    }
}

Describe 'Read-CABConfirm handles stdin-at-EOF safely' {
    It 'returns the default ("yes") when Read-Host returns null and Default=$true' {
        Mock -CommandName Read-Host -MockWith { return $null }
        $r = Read-CABConfirm -Question 'Continue?' -Default $true
        $r | Should -Be 'yes'
    }
    It 'returns "no" when Read-Host returns null and Default=$false' {
        Mock -CommandName Read-Host -MockWith { return $null }
        $r = Read-CABConfirm -Question 'Continue?' -Default $false
        $r | Should -Be 'no'
    }
}
