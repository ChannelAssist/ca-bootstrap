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
        if ($Script:CABTuiProcess -and -not $Script:CABTuiProcess.HasExited) {
            try { $Script:CABTuiProcess.Kill() } catch {}
        }
        if ($script:stubPath -and (Test-Path $script:stubPath)) {
            Remove-Item $script:stubPath -Force -ErrorAction SilentlyContinue
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
Start-Sleep -Seconds 5
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
Start-Sleep -Seconds 5
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
        # No stub started: if a send is attempted, $Script:CABTuiProcess
        # is null and Send-CABTuiEvent would throw. So the test passing
        # proves we short-circuit before the send.
        $r = Read-CABConfirm -Question 'q' -Default $true -AnswerKey 'k'
        $r | Should -Be 'no'
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
Start-Sleep -Seconds 5
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
