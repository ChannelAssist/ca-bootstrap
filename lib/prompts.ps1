#requires -Version 7.0
# lib/prompts.ps1 — interactive prompt helpers.
#
# All prompts respect $Script:CABootstrapUnattended; in unattended mode
# they read from the supplied answers hashtable instead of asking.

$Script:CABootstrapUnattended = $false
$Script:CABootstrapAnswers    = @{}
$Script:CABootstrapTuiMode    = $false

function Set-CABPromptMode {
    [CmdletBinding()]
    param(
        [bool]$Unattended,
        [hashtable]$Answers,
        [bool]$TuiMode
    )
    $Script:CABootstrapUnattended = $Unattended
    if ($Answers)        { $Script:CABootstrapAnswers = $Answers }
    if ($PSBoundParameters.ContainsKey('TuiMode')) {
        $Script:CABootstrapTuiMode = $TuiMode
    }
}

# New-CABPromptId — short unique id used to correlate prompt requests
# with answer replies over the RPC bridge.
function New-CABPromptId {
    "p-$([Guid]::NewGuid().ToString('N').Substring(0, 12))"
}

# Read-CABConfirm — yes/no prompt with a default.
#   $Default: $true → "[Y/n/q]", $false → "[y/N/q]"
#   Returns: one of 'yes' | 'no' | 'quit' (always a string).
#
# Callers should compare against the constants. The single-typed return
# avoids a foot-gun where `$result -eq 'quit'` would coerce a $true bool
# to 'true' and silently match. Two callable predicates are exported as
# convenience: Test-CABYes / Test-CABQuit.
function Read-CABConfirm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Question,
        [bool]$Default = $true,
        [string]$AnswerKey
    )
    $defaultStr = if ($Default) { 'yes' } else { 'no' }

    # TUI mode: dispatch through the JSON-RPC bridge so the Python
    # front-end renders the prompt with stock widgets (Button row).
    # Unattended-mode answers still take priority, so a -ConfigFile run
    # never blocks on the bridge.
    if ($Script:CABootstrapTuiMode -and -not $Script:CABootstrapUnattended) {
        $promptId = New-CABPromptId
        Send-CABTuiEvent -Event @{
            type     = 'prompt'
            id       = $promptId
            kind     = 'confirm'
            question = $Question
            default  = $defaultStr
            options  = @('yes', 'no', 'quit')
        }
        $answer = Receive-CABTuiAnswer -PromptId $promptId
        if (-not $answer) { return $defaultStr }   # bridge died → safe default
        return [string]$answer
    }

    if ($Script:CABootstrapUnattended) {
        if ($AnswerKey -and $Script:CABootstrapAnswers.ContainsKey($AnswerKey)) {
            $a = $Script:CABootstrapAnswers[$AnswerKey]
            # Accept both legacy bool answers (from old answers.yaml files)
            # and the new string form for forward compatibility.
            if ($a -is [bool])   { return $(if ($a) { 'yes' } else { 'no' }) }
            if ($a -is [string]) {
                $low = $a.ToLowerInvariant()
                if ($low -in 'yes','y','true')  { return 'yes' }
                if ($low -in 'no','n','false')  { return 'no' }
                if ($low -in 'quit','q')        { return 'quit' }
            }
        }
        return $defaultStr
    }

    $hint = if ($Default) { '[Y/n/q]' } else { '[y/N/q]' }
    while ($true) {
        Write-Host "  $Question $hint " -NoNewline
        $ans = Read-Host
        if ([string]::IsNullOrWhiteSpace($ans)) { return $defaultStr }
        switch -Regex ($ans.Trim()) {
            '^[Yy]([Ee][Ss])?$' { return 'yes' }
            '^[Nn][Oo]?$'       { return 'no' }
            '^[Qq](uit)?$'      { return 'quit' }
            default             { Write-CABColor Red "  Please answer y, n, or q." }
        }
    }
}

function Test-CABYes  { param([string]$R) $R -eq 'yes'  }
function Test-CABNo   { param([string]$R) $R -eq 'no'   }
function Test-CABQuit { param([string]$R) $R -eq 'quit' }

# Read-CABChoice — multi-option prompt.
#   $Options: array of @{ Key='Y'; Label='Yes (install all)' }
#   Returns: matched Key (case-insensitive), or 'quit'.
function Read-CABChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Question,
        [Parameter(Mandatory)] [array]$Options,
        [string]$Default,
        [string]$AnswerKey
    )
    # TUI mode: render as a RadioSet of RadioButtons.
    if ($Script:CABootstrapTuiMode -and -not $Script:CABootstrapUnattended) {
        $promptId = New-CABPromptId
        $optionsForRpc = $Options | ForEach-Object { @{ value = $_.Key; label = $_.Label } }
        Send-CABTuiEvent -Event @{
            type     = 'prompt'
            id       = $promptId
            kind     = 'choice'
            question = $Question
            options  = @($optionsForRpc)
            default  = $Default
        }
        $answer = Receive-CABTuiAnswer -PromptId $promptId
        if (-not $answer) { return $Default }
        return [string]$answer
    }
    if ($Script:CABootstrapUnattended) {
        if ($AnswerKey -and $Script:CABootstrapAnswers.ContainsKey($AnswerKey)) {
            return [string]$Script:CABootstrapAnswers[$AnswerKey]
        }
        if ($Default) { return $Default }
        throw "Unattended mode: no answer provided for '$Question' (key: $AnswerKey)"
    }
    $hint = ($Options | ForEach-Object { "[$($_.Key)]$($_.Label)" }) -join '  '
    while ($true) {
        Write-Host ''
        Write-Host "  $Question"
        Write-Host "    $hint"
        Write-Host "  > " -NoNewline
        $ans = (Read-Host).Trim()
        if ([string]::IsNullOrWhiteSpace($ans) -and $Default) { return $Default }
        $match = $Options | Where-Object { $_.Key -ieq $ans } | Select-Object -First 1
        if ($match) { return $match.Key }
        if ($ans -match '^[Qq](uit)?$') { return 'quit' }
        Write-CABColor Red "  Unrecognized choice. Try one of: $($Options.Key -join ', ')"
    }
}

# Read-CABRecovery — step-failure recovery prompt. TUI mode renders a
# prominent panel with the failure details and Retry / Skip / Quit
# buttons; CLI mode preserves the existing "always quits to rollback"
# behavior by returning 'quit' immediately.
#
# Returns one of: 'retry' | 'skip' | 'quit'.
function Read-CABRecovery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StepId,
        [Parameter(Mandatory)][string]$Details,
        [string]$Default = 'retry'
    )
    if ($Script:CABootstrapTuiMode -and -not $Script:CABootstrapUnattended) {
        $promptId = New-CABPromptId
        Send-CABTuiEvent -Event @{
            type     = 'prompt'
            id       = $promptId
            kind     = 'recovery'
            question = "Step '$StepId' failed"
            details  = $Details
            options  = @('retry', 'skip', 'quit')
            default  = $Default
        }
        $answer = Receive-CABTuiAnswer -PromptId $promptId
        if (-not $answer) { return 'quit' }   # bridge died → fail safe
        $answer = [string]$answer
        if ($answer -in 'retry','skip','quit') { return $answer }
        return 'quit'
    }
    # CLI mode (and unattended): preserve long-standing behavior of going
    # straight to the rollback offer. A future phase can add a CLI version
    # of this prompt; phase 6 is TUI-scoped.
    return 'quit'
}

# Functions exported automatically when this file is dot-sourced.
