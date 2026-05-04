#requires -Version 7.0
# tests/lib/prompts-tui.tests.ps1 — end-to-end test for Read-CABConfirm /
# Read-CABChoice dispatch in TuiMode.
#
# We can't easily mock Send-CABTuiEvent / Receive-CABTuiAnswer at the
# script-scope level (PowerShell's function-table scoping makes the
# override invisible to dot-sourced callers), so this file uses a real
# pwsh subprocess as the "child" — it reads the prompt event from
# stdin and writes a scripted answer to stdout. Same wire protocol
# the real Python child uses.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/prompts.ps1')
    . (Join-Path $repoRoot 'lib/tui-rpc.ps1')

    function Start-StubChild {
        param([string]$AnswerScript)
        $stubFile = Join-Path ([System.IO.Path]::GetTempPath()) "cab-prompt-stub-$(Get-Random).ps1"
        Set-Content -Path $stubFile -Value $AnswerScript
        $script:stubPath = $stubFile

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
        return $proc
    }
    function Stop-StubChild {
        if ($Script:CABTuiProcess) {
            if (-not $Script:CABTuiProcess.HasExited) {
                # Close stdin first so the stub's `[Console]::In.ReadLine()`
                # returns null and the stub exits naturally. Kill is the
                # safety net.
                try { $Script:CABTuiProcess.StandardInput.Close() } catch {}
                if (-not $Script:CABTuiProcess.WaitForExit(2000)) {
                    try { $Script:CABTuiProcess.Kill() } catch {}
                    # WaitForExit *after* Kill so the OS reaps the
                    # process before we move on; without this the
                    # next test can still see HasExited == false on
                    # a killed-but-not-yet-reaped child, and on
                    # interrupt the stub orphans for its full sleep.
                    try { $Script:CABTuiProcess.WaitForExit(2000) | Out-Null } catch {}
                }
            }
            try { $Script:CABTuiProcess.Dispose() } catch {}
            $Script:CABTuiProcess = $null
        }
        if ($script:stubPath -and (Test-Path $script:stubPath)) {
            Remove-Item $script:stubPath -Force -ErrorAction SilentlyContinue
            $script:stubPath = $null
        }
    }
}

Describe 'Read-CABConfirm in TuiMode (real subprocess)' {
    BeforeEach { Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true }
    AfterEach  { Stop-StubChild; Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $false }

    It 'sends a confirm prompt and returns the child-supplied answer' {
        # Stub: read one line, parse as the prompt, reply with answer 'no'.
        $stub = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
if ($msg.type -eq 'prompt') {
    $reply = @{ type = 'answer'; id = $msg.id; value = 'no' } | ConvertTo-Json -Compress
    [Console]::Out.WriteLine($reply)
    [Console]::Out.Flush()
}
'@
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Read-CABConfirm -Question 'Use default workspace?' -Default $true
        $r | Should -Be 'no'
    }

    It 'sends a confirm prompt with the right shape (verified by stub echoing the prompt back)' {
        # Stub: echo the received prompt back inside an answer.value.
        $stub = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
$reply = @{ type = 'answer'; id = $msg.id; value = "kind=$($msg.kind);q=$($msg.question);d=$($msg.default);opts=$($msg.options -join ',')" } | ConvertTo-Json -Compress
[Console]::Out.WriteLine($reply)
[Console]::Out.Flush()
'@
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Read-CABConfirm -Question 'Use default workspace?' -Default $true
        $r | Should -Be 'kind=confirm;q=Use default workspace?;d=yes;opts=yes,no,quit'
    }

    It 'falls back to the default if the child closes stdin without answering' {
        # Stub: read prompt, exit immediately (no answer).
        $stub = '[Console]::In.ReadLine() | Out-Null'
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Read-CABConfirm -Question 'q' -Default $true
        $r | Should -Be 'yes'
    }

    It 'unattended mode takes priority — no event sent at all' {
        Set-CABPromptMode -Unattended $true -Answers @{ 'k' = 'no' } -TuiMode $true
        # No stub started: $Script:CABTuiProcess is null because
        # AfterEach's Stop-StubChild explicitly nulls it. If a send
        # were attempted, Send-CABTuiEvent would throw "process is not
        # running". The test passing proves the unattended branch
        # short-circuits before the send.
        $r = Read-CABConfirm -Question 'q' -Default $true -AnswerKey 'k'
        $r | Should -Be 'no'
    }

}

Describe 'Invoke-CABTuiPrompt fallback contract' {
    BeforeEach { Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true }
    AfterEach  { Stop-StubChild; Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $false }

    It 'returns ok=$false and disables TuiMode when Send throws (dead bridge)' {
        # No stub child — $Script:CABTuiProcess is null, so Send-CABTuiEvent
        # throws "cab-tui process is not running". The helper must catch,
        # disable TuiMode, and surface the failure so callers fall back
        # to CLI instead of aborting setup.
        $Script:CABTuiProcess = $null
        $r = Invoke-CABTuiPrompt -PromptId 'p1' -Event @{
            type = 'prompt'; id = 'p1'; kind = 'confirm';
            question = 'q'; default = 'yes'; options = @('yes','no','quit')
        }
        $r.ok | Should -BeFalse
        $r.value | Should -BeNullOrEmpty
        $Script:CABootstrapTuiMode | Should -BeFalse
    }

    It 'returns ok=$false and disables TuiMode when child closes mid-Receive' {
        # Stub reads the prompt then exits without replying — Receive
        # returns $null. Helper must treat $null identically to a Send
        # exception (both mean "the child can't drive the UI any more").
        $stub = '[Console]::In.ReadLine() | Out-Null'
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Invoke-CABTuiPrompt -PromptId 'p2' -Event @{
            type = 'prompt'; id = 'p2'; kind = 'confirm';
            question = 'q'; default = 'yes'; options = @('yes','no','quit')
        }
        $r.ok | Should -BeFalse
        $Script:CABootstrapTuiMode | Should -BeFalse
    }

    It 'returns ok=$true with the answer when the bridge replies normally' {
        $stub = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
$reply = @{ type = 'answer'; id = $msg.id; value = 'no' } | ConvertTo-Json -Compress
[Console]::Out.WriteLine($reply)
[Console]::Out.Flush()
'@
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Invoke-CABTuiPrompt -PromptId 'p3' -Event @{
            type = 'prompt'; id = 'p3'; kind = 'confirm';
            question = 'q'; default = 'yes'; options = @('yes','no','quit')
        }
        $r.ok | Should -BeTrue
        $r.value | Should -Be 'no'
        $Script:CABootstrapTuiMode | Should -BeTrue
    }
}

Describe 'Read-CABRecovery in TuiMode (real subprocess)' {
    BeforeEach { Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true }
    AfterEach  { Stop-StubChild; Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $false }

    It 'sends a recovery prompt with details and returns retry/skip/quit' {
        # Stub: read prompt, reply with 'skip'.
        $stub = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
$reply = @{ type = 'answer'; id = $msg.id; value = 'skip' } | ConvertTo-Json -Compress
[Console]::Out.WriteLine($reply)
[Console]::Out.Flush()
'@
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Read-CABRecovery -StepId '60-repos' -Details 'gh auth required'
        $r | Should -Be 'skip'
    }

    It 'sends prompt of kind=recovery with the expected fields' {
        # Side-channel: stub writes the parsed prompt to a temp file so we
        # can inspect its shape, then replies with a whitelisted value.
        # Using the echo-as-answer trick like the confirm test won't work
        # here: Read-CABRecovery enforces a strict {retry,skip,quit} answer
        # set and falls back to 'quit' on anything else (correct hardening).
        $script:capFile = Join-Path ([System.IO.Path]::GetTempPath()) "cab-rcv-cap-$(Get-Random).json"
        $stub = @"
`$line = [Console]::In.ReadLine()
`$msg  = `$line | ConvertFrom-Json
`$out  = '$($script:capFile -replace '\\','\\')'
Set-Content -Path `$out -Value `$line
`$reply = @{ type = 'answer'; id = `$msg.id; value = 'retry' } | ConvertTo-Json -Compress
[Console]::Out.WriteLine(`$reply)
[Console]::Out.Flush()
"@
        Start-StubChild -AnswerScript $stub | Out-Null
        try {
            $r = Read-CABRecovery -StepId '60-repos' -Details 'auth needed'
            $r | Should -Be 'retry'
            Test-Path $script:capFile | Should -BeTrue
            $captured = Get-Content $script:capFile | ConvertFrom-Json
            $captured.kind     | Should -Be 'recovery'
            $captured.question | Should -Be "Step '60-repos' failed"
            $captured.details  | Should -Be 'auth needed'
            $captured.default  | Should -Be 'retry'
            ($captured.options -join ',') | Should -Be 'retry,skip,quit'
        } finally {
            if ($script:capFile -and (Test-Path $script:capFile)) {
                Remove-Item $script:capFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns quit if the bridge closes without answering (fail-safe)' {
        $stub = '[Console]::In.ReadLine() | Out-Null'
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Read-CABRecovery -StepId 'x' -Details 'y'
        $r | Should -Be 'quit'
    }

    It 'returns quit when not in TuiMode (CLI fallback)' {
        Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $false
        # No stub started — if Read-CABRecovery tried to send, it would
        # throw on the null bridge. The test passing proves the early
        # return path.
        $r = Read-CABRecovery -StepId 'x' -Details 'y'
        $r | Should -Be 'quit'
    }
}

Describe 'Read-CABChoice in TuiMode (real subprocess)' {
    BeforeEach { Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $true }
    AfterEach  { Stop-StubChild; Set-CABPromptMode -Unattended $false -Answers @{} -TuiMode $false }

    It 'sends choice options as {value, label} pairs and returns the child answer' {
        $stub = @'
$line = [Console]::In.ReadLine()
$msg = $line | ConvertFrom-Json
$summary = ($msg.options | ForEach-Object { "$($_.value):$($_.label)" }) -join '|'
$reply = @{ type = 'answer'; id = $msg.id; value = $summary } | ConvertTo-Json -Compress
[Console]::Out.WriteLine($reply)
[Console]::Out.Flush()
'@
        Start-StubChild -AnswerScript $stub | Out-Null
        $r = Read-CABChoice -Question 'Pick' -Options @(
            @{ Key = 'Y'; Label = 'Yes' },
            @{ Key = 'n'; Label = 'No (skip)' },
            @{ Key = 's'; Label = 'Select' }
        ) -Default 'Y'
        $r | Should -Be 'Y:Yes|n:No (skip)|s:Select'
    }
}
