#requires -Version 7.0
# lib/prompts.ps1 — interactive prompt helpers (Read-Host wizard).
#
# All prompts respect $Script:CABootstrapUnattended; in unattended mode
# they read from the supplied answers hashtable instead of asking.

$Script:CABootstrapUnattended = $false
$Script:CABootstrapAnswers    = @{}

function Set-CABPromptMode {
    [CmdletBinding()]
    param(
        [bool]$Unattended,
        [hashtable]$Answers
    )
    $Script:CABootstrapUnattended = $Unattended
    # Use ContainsKey instead of `if ($Answers)`: an empty hashtable
    # is falsy in PowerShell, but callers explicitly pass `-Answers @{}`
    # to reset prior answers between commands. Without this guard the
    # reset would silently no-op and stale answers from a previous
    # unattended run would leak into the next one.
    if ($PSBoundParameters.ContainsKey('Answers')) {
        $Script:CABootstrapAnswers = $Answers
    }
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

# Functions exported automatically when this file is dot-sourced.
