#requires -Version 7.0
# tests/lib/setup-tui-events.tests.ps1 — verifies setup emits the
# step.start / step.end events the TUI expects when CABootstrapTuiMode
# is true. Verified end-to-end: a stub child captures the events and we
# assert the JSON shapes.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'lib/git-ops.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
    . (Join-Path $repoRoot 'lib/answers.ps1')
    . (Join-Path $repoRoot 'lib/tui-rpc.ps1')
    . (Join-Path $repoRoot 'commands/setup.ps1')
}

Describe 'setup loop emits step events when TuiMode is set' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-tuiev-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState

        # Stub child: read all stdin until eof, write each line to a
        # capture file. The setup loop will run very fast; we kill the
        # stub after.
        $script:capPath = Join-Path $script:tempState 'captured.jsonl'
        [void](New-Item -ItemType Directory -Path $script:tempState -Force)

        $stub = @"
`$out = '$($script:capPath -replace '\\','\\')'
while (`$true) {
    `$line = [Console]::In.ReadLine()
    if (`$null -eq `$line) { break }
    Add-Content -Path `$out -Value `$line
}
"@
        $stubFile = Join-Path $script:tempState 'capture-stub.ps1'
        Set-Content -Path $stubFile -Value $stub
        $script:stubFile = $stubFile

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = "-NoLogo -NoProfile -File `"$stubFile`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $Script:CABTuiProcess = $proc

        Set-CABPromptMode -Unattended $true -Answers @{
            'welcome.continue'         = 'no'   # quit immediately at welcome
        } -TuiMode $true

        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'
    }
    AfterEach {
        try { Stop-Transcript | Out-Null } catch {}
        Unlock-CABSession
        if ($Script:CABTuiProcess -and -not $Script:CABTuiProcess.HasExited) {
            try { $Script:CABTuiProcess.StandardInput.Close() } catch {}
            $Script:CABTuiProcess.WaitForExit(2000) | Out-Null
            if (-not $Script:CABTuiProcess.HasExited) {
                try { $Script:CABTuiProcess.Kill() } catch {}
            }
        }
        Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $false
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
        if ($script:tempState -and (Test-Path $script:tempState)) {
            Remove-Item -Recurse -Force $script:tempState -ErrorAction SilentlyContinue
        }
    }

    It 'emits step.start before each step and step.end after' {
        $context = @{
            RepoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
            Version  = 'test'
            Command  = 'setup'
            Unattended = $true
        }
        # User answers 'no' at welcome, which the welcome step treats
        # as quit — so only step 1 runs to completion before we exit.
        $exitCode = Invoke-CABCommandSetup -Context $context

        # Drain the stub: close its stdin so the read loop exits.
        $Script:CABTuiProcess.StandardInput.Close()
        $Script:CABTuiProcess.WaitForExit(2000) | Out-Null

        Test-Path $script:capPath | Should -BeTrue
        $events = Get-Content $script:capPath | ForEach-Object { $_ | ConvertFrom-Json }
        # We expect: a step.start for 10-welcome, then a step.end with
        # status='quit'.
        $stepEvents = $events | Where-Object { $_.type -eq 'step' }
        $stepEvents.Count | Should -BeGreaterThan 0
        $stepEvents[0].phase | Should -Be 'start'
        $stepEvents[0].step  | Should -Be '10-welcome'
        $stepEvents[0].title | Should -Be 'Welcome'
        $stepEvents[0].total | Should -Be 8
        # The matching end (could be 'end' with status=quit, since
        # 'no' at welcome maps to 'quit' status in step 10).
        $endEvent = $stepEvents | Where-Object { $_.phase -in 'end','skip' } | Select-Object -First 1
        $endEvent | Should -Not -BeNullOrEmpty
        $endEvent.step | Should -Be '10-welcome'
    }
}
