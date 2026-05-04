#requires -Version 7.0
# tests/lib/setup-recovery.tests.ps1 — drives the setup orchestrator's
# retry loop end-to-end. Spawns a stub TUI child that replies to the
# recovery prompt, and synthesizes a single failing step so the loop
# has something to recover from.

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

    # A test-double step file that fails the first N invocations then
    # succeeds. Lets us exercise both the retry path (N>=1) and the
    # eventual-success path without needing real prereqs / network.
    # Defined inside BeforeAll so Pester's scope sees it.
    function Write-FailingStepFile {
        param(
            [string]$Path,
            [int]$FailUntilAttempt,
            [string]$CounterFile
        )
        Set-Content -Path $CounterFile -Value '0'
        $body = @"
function Invoke-CABStep10 {
    param([hashtable]`$Context)
    `$counter = [int](Get-Content -Path '$CounterFile')
    `$counter++
    Set-Content -Path '$CounterFile' -Value `$counter
    if (`$counter -le $FailUntilAttempt) {
        return @{ status = 'fail'; details = "synthetic failure attempt `$counter" }
    }
    return @{ status = 'ok'; details = "succeeded on attempt `$counter" }
}
"@
        Set-Content -Path $Path -Value $body
    }
}

Describe 'setup orchestrator retry loop (TuiMode)' {
    BeforeEach {
        $script:tempState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-rcvloop-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tempState
        Reset-CABJournalState
        [void](New-Item -ItemType Directory -Path $script:tempState -Force)

        $script:counterFile = Join-Path $script:tempState 'attempts.txt'

        # Override step 10 with a failing-then-succeeding double. We
        # rebuild $stepIds in the orchestrator to be just 10-welcome;
        # the synthetic step file is dropped into a temp tree and the
        # repo root in the context is pointed there.
        $script:fakeRoot = Join-Path $script:tempState 'fake-repo'
        New-Item -ItemType Directory -Path (Join-Path $script:fakeRoot 'steps') -Force | Out-Null
        # The orchestrator runs step ids in a fixed order; we only need
        # the first one to fire, then quit before the others (which we
        # also stub as no-ops returning 'quit' so the test ends fast).
        Write-FailingStepFile -Path (Join-Path $script:fakeRoot 'steps/10-welcome.ps1') `
            -FailUntilAttempt 1 -CounterFile $script:counterFile
        # Stub all the other steps as immediate-success so we don't
        # need real workspace/network to complete the test.
        foreach ($id in '40-workspace','20-prereqs','30-gh-auth','50-folders','60-repos','70-git-identity','80-extras') {
            $num = ($id -split '-')[0]
            Set-Content -Path (Join-Path $script:fakeRoot "steps/$id.ps1") -Value @"
function Invoke-CABStep$num { param([hashtable]`$Context) @{ status='ok'; details='stub' } }
"@
        }
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

    It "retries a failing step when the user picks 'retry'" {
        # Stub TUI: ignore everything except the recovery prompt; reply
        # 'retry' to the first one. Subsequent prompts (if any) get 'quit'
        # so we don't loop forever in case the test goes wrong.
        $repliedFlag = Join-Path $script:tempState 'replied.flag'
        $stub = @"
`$flagPath = '$($repliedFlag -replace '\\','\\')'
while (`$true) {
    `$line = [Console]::In.ReadLine()
    if (`$null -eq `$line) { break }
    try { `$msg = `$line | ConvertFrom-Json } catch { continue }
    if (`$msg.type -eq 'prompt' -and `$msg.kind -eq 'recovery') {
        `$value = if (Test-Path `$flagPath) { 'quit' } else { 'retry' }
        if (-not (Test-Path `$flagPath)) { Set-Content -Path `$flagPath -Value 'yes' }
        `$reply = @{ type='answer'; id=`$msg.id; value=`$value } | ConvertTo-Json -Compress
        [Console]::Out.WriteLine(`$reply)
        [Console]::Out.Flush()
    }
}
"@
        $stubFile = Join-Path $script:tempState 'recover-stub.ps1'
        Set-Content -Path $stubFile -Value $stub

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

        Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true

        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'

        $context = @{
            RepoRoot   = $script:fakeRoot
            Version    = 'test'
            Command    = 'setup'
            Unattended = $false
        }

        $exitCode = Invoke-CABCommandSetup -Context $context

        # Step 10 should have run twice (one fail + one success).
        $finalCount = [int](Get-Content $script:counterFile)
        $finalCount | Should -Be 2
        # Whole orchestrator should succeed because all subsequent steps
        # are no-op success stubs.
        $exitCode | Should -Be 0
    }

    It "emits step.start before each retry attempt and a skip step.end after a 'skip' recovery" {
        # Stub: capture every inbound message to a file so we can assert
        # on the sequence of step events. Reply 'retry' to the first
        # recovery prompt, 'skip' to the second.
        $captureFile = Join-Path $script:tempState 'events.jsonl'
        $stub = @"
`$out = '$($captureFile -replace '\\','\\')'
`$replies = @('retry', 'skip')
`$idx = 0
while (`$true) {
    `$line = [Console]::In.ReadLine()
    if (`$null -eq `$line) { break }
    Add-Content -Path `$out -Value `$line
    try { `$msg = `$line | ConvertFrom-Json } catch { continue }
    if (`$msg.type -eq 'prompt' -and `$msg.kind -eq 'recovery') {
        `$value = if (`$idx -lt `$replies.Count) { `$replies[`$idx] } else { 'quit' }
        `$idx++
        `$reply = @{ type = 'answer'; id = `$msg.id; value = `$value } | ConvertTo-Json -Compress
        [Console]::Out.WriteLine(`$reply)
        [Console]::Out.Flush()
    }
}
"@
        # Step 10 fails twice (so retry runs, retried attempt also fails,
        # then skip moves on). FailUntilAttempt=999 keeps it failing.
        Write-FailingStepFile -Path (Join-Path $script:fakeRoot 'steps/10-welcome.ps1') `
            -FailUntilAttempt 999 -CounterFile $script:counterFile

        $stubFile = Join-Path $script:tempState 'evt-stub.ps1'
        Set-Content -Path $stubFile -Value $stub

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

        Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true
        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'

        $context = @{ RepoRoot = $script:fakeRoot; Version = 'test'; Command = 'setup'; Unattended = $false }
        Invoke-CABCommandSetup -Context $context | Out-Null

        # Drain.
        $Script:CABTuiProcess.StandardInput.Close()
        $Script:CABTuiProcess.WaitForExit(2000) | Out-Null

        Test-Path $captureFile | Should -BeTrue
        $events = Get-Content $captureFile | ForEach-Object { $_ | ConvertFrom-Json }
        $stepEvents = @($events | Where-Object { $_.type -eq 'step' -and $_.step -eq '10-welcome' })

        # We expect, in order, for step 10:
        #   1. step.start    (initial attempt)
        #   2. step.end fail (first failure)
        #   3. step.start    (retry attempt — re-flips the tree to ▶)
        #   4. step.end fail (retry also failed)
        #   5. step.skip     (after 'skip' recovery — clears the ✗)
        $stepEvents.Count | Should -BeGreaterOrEqual 5
        $stepEvents[0].phase | Should -Be 'start'
        $stepEvents[1].phase | Should -Be 'end'
        $stepEvents[1].status | Should -Be 'fail'
        $stepEvents[2].phase | Should -Be 'start'   # retry re-emits start
        $stepEvents[3].phase | Should -Be 'end'
        $stepEvents[3].status | Should -Be 'fail'
        # The recovery 'skip' produces a corrective step.skip event so the
        # TUI tree drops the ✗ and shows ↷ instead.
        $skipEvent = $stepEvents | Where-Object { $_.phase -eq 'skip' } | Select-Object -First 1
        $skipEvent | Should -Not -BeNullOrEmpty
        $skipEvent.status | Should -Be 'skip'
    }

    It "skips a failing step when the user picks 'skip' and continues to the next" {
        # Same stub shape but always answers 'skip'.
        $stub = @'
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    try { $msg = $line | ConvertFrom-Json } catch { continue }
    if ($msg.type -eq 'prompt' -and $msg.kind -eq 'recovery') {
        $reply = @{ type='answer'; id=$msg.id; value='skip' } | ConvertTo-Json -Compress
        [Console]::Out.WriteLine($reply)
        [Console]::Out.Flush()
    }
}
'@
        # Step 10 fails forever: FailUntilAttempt=999, but with 'skip' we
        # expect exactly one invocation (no retry).
        Write-FailingStepFile -Path (Join-Path $script:fakeRoot 'steps/10-welcome.ps1') `
            -FailUntilAttempt 999 -CounterFile $script:counterFile

        $stubFile = Join-Path $script:tempState 'skip-stub.ps1'
        Set-Content -Path $stubFile -Value $stub

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

        Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true

        Read-CABJournal | Out-Null
        Start-CABSession -Command 'setup' -Version 'test'

        $context = @{
            RepoRoot   = $script:fakeRoot
            Version    = 'test'
            Command    = 'setup'
            Unattended = $false
        }

        $exitCode = Invoke-CABCommandSetup -Context $context
        # Step 10 invoked once (no retry on 'skip').
        [int](Get-Content $script:counterFile) | Should -Be 1
        # Subsequent stubs all succeed → overall exit 0.
        $exitCode | Should -Be 0
    }
}
