#requires -Version 7.0
# lib/prompts.ps1 — interactive prompt helpers.
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
    if ($Answers) { $Script:CABootstrapAnswers = $Answers }
}

# Read-CABConfirm — yes/no prompt with a default.
#   $Default: $true → "[Y/n]", $false → "[y/N]"
#   Returns: $true / $false / 'quit'
function Read-CABConfirm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Question,
        [bool]$Default = $true,
        [string]$AnswerKey
    )
    if ($Script:CABootstrapUnattended) {
        if ($AnswerKey -and $Script:CABootstrapAnswers.ContainsKey($AnswerKey)) {
            return [bool]$Script:CABootstrapAnswers[$AnswerKey]
        }
        return $Default
    }
    $hint = if ($Default) { '[Y/n/q]' } else { '[y/N/q]' }
    while ($true) {
        Write-Host "  $Question $hint " -NoNewline
        $ans = Read-Host
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        switch -Regex ($ans.Trim()) {
            '^[Yy]([Ee][Ss])?$' { return $true }
            '^[Nn][Oo]?$'       { return $false }
            '^[Qq](uit)?$'      { return 'quit' }
            default             { Write-CABColor Red "  Please answer y, n, or q." }
        }
    }
}

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
