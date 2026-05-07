#requires -Version 7.0
# tests/lib/redaction.tests.ps1 — token redaction in journal entries.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
}

Describe 'Test-CABContainsSensitive' {
    It 'detects gh CLI tokens' {
        Test-CABContainsSensitive 'ghp_abcdefghijklmnopqrstuvwxyz0123456789ABC' | Should -BeTrue
        Test-CABContainsSensitive 'ghu_abcdefghijklmnopqrstuvwxyz0123456789ABC' | Should -BeTrue
    }
    It 'detects fine-grained PAT' {
        Test-CABContainsSensitive 'github_pat_1234567890abcdef1234567890abcdef' | Should -BeTrue
    }
    It 'detects JWT' {
        $jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4ifQ'
        Test-CABContainsSensitive "authorization: Bearer $jwt" | Should -BeTrue
    }
    It 'detects PEM private keys' {
        Test-CABContainsSensitive '-----BEGIN RSA PRIVATE KEY-----' | Should -BeTrue
    }
    It 'returns false for ordinary strings' {
        Test-CABContainsSensitive '/Users/user/Documents/Projects/ChannelAssistDev' | Should -BeFalse
        Test-CABContainsSensitive 'ChannelAssist/Keystone' | Should -BeFalse
    }
}

Describe 'Hide-CABSensitive' {
    It 'replaces gh tokens with <redacted>' {
        $r = Hide-CABSensitive 'token=ghp_abcdefghijklmnopqrstuvwxyz0123456789ABC end'
        $r | Should -Be 'token=<redacted> end'
    }
    It 'leaves non-sensitive text alone' {
        Hide-CABSensitive 'no secrets here' | Should -Be 'no secrets here'
    }
}

Describe 'Add-CABJournalEntry redacts sensitive Data fields' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-redact-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        Unlock-CABSession
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
    }

    It 'redacts a token-shaped string in entry data' {
        $entry = Add-CABJournalEntry -Step '99-test' -Action 'pretend' -Data @{
            secret = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789ABC'
            normal = 'plain-string'
        }
        $entry.secret | Should -Be '<redacted>'
        $entry.normal | Should -Be 'plain-string'
    }
}
