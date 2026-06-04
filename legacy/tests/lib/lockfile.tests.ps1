#requires -Version 7.0
# tests/lib/lockfile.tests.ps1 — concurrency / single-writer guarantee.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
}

Describe 'Lock-CABSession / Unlock-CABSession' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-lock-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState
    }
    AfterEach {
        Unlock-CABSession
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
    }

    It 'acquires the lock when no other session holds it' {
        Lock-CABSession | Should -BeTrue
        Test-Path (Join-Path $script:tempState 'session.lock.d') | Should -BeTrue
    }

    It 'rejects a second concurrent acquire (via subprocess)' {
        Lock-CABSession | Should -BeTrue

        # Try to grab the lock from a second pwsh process — must fail.
        $cmd = @"
`$env:CA_BOOTSTRAP_STATE = '$script:tempState'
. '$((Resolve-Path "$PSScriptRoot/../../lib/yaml.ps1").Path)'
. '$((Resolve-Path "$PSScriptRoot/../../lib/journal.ps1").Path)'
Reset-CABJournalState
try { Lock-CABSession -TimeoutMs 500 } catch { Write-Host "REFUSED" }
"@
        $output = & pwsh -NoLogo -NoProfile -Command $cmd 2>&1 | Out-String
        $output | Should -Match 'REFUSED|already running'
    }

    It 'releases the lock so a subsequent run can acquire' {
        Lock-CABSession | Should -BeTrue
        Unlock-CABSession
        # Now try again — should succeed.
        Lock-CABSession | Should -BeTrue
    }
}
