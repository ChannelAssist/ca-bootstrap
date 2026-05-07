#requires -Version 7.0
# lib/ui.ps1 — color output, headers, banners, status icons.

$Script:CABootstrapColor = -not ($env:NO_COLOR -or $env:CA_BOOTSTRAP_NO_COLOR)

function Write-CABColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ConsoleColor]$Color,
        [Parameter(Mandatory, ValueFromPipeline)] [AllowEmptyString()] [string]$Text,
        [switch]$NoNewLine
    )
    process {
        if ($Script:CABootstrapColor) {
            $orig = [Console]::ForegroundColor
            [Console]::ForegroundColor = $Color
            try {
                if ($NoNewLine) { Write-Host -NoNewline $Text } else { Write-Host $Text }
            }
            finally { [Console]::ForegroundColor = $orig }
        }
        else {
            if ($NoNewLine) { Write-Host -NoNewline $Text } else { Write-Host $Text }
        }
    }
}

function Write-CABHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$Title)
    $bar = '=' * [Math]::Min(70, $Title.Length + 4)
    Write-Host ''
    Write-CABColor Cyan $bar
    Write-CABColor Cyan "  $Title"
    Write-CABColor Cyan $bar
}

function Write-CABStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]$Number,
        [Parameter(Mandatory)] [int]$Total,
        [Parameter(Mandatory)] [string]$Title
    )
    Write-Host ''
    # Total = 0 means we're being invoked outside the setup wizard
    # (repair, repair --target, ad-hoc step run). The "Step N/0"
    # rendering reads as a count-out-of-bounds, so drop the X/Y suffix
    # in that mode and just show the title.
    if ($Total -gt 0) {
        Write-CABColor White "Step $Number/$Total — $Title"
    } else {
        Write-CABColor White "$Title"
    }
}

function Write-CABStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('ok','warn','fail','info','skip')] [string]$Status,
        [Parameter(Mandatory)] [string]$Message,
        [string]$Detail
    )
    $icon, $color = switch ($Status) {
        'ok'   { '✓', 'Green'   }
        'warn' { '⚠', 'Yellow'  }
        'fail' { '✗', 'Red'     }
        'info' { 'ⓘ', 'Cyan'    }
        'skip' { '↷', 'DarkGray' }
    }
    Write-CABColor ([ConsoleColor]$color) "  $icon  $Message" -NoNewLine
    if ($Detail) { Write-Host "  ($Detail)" } else { Write-Host '' }
}

function Write-CABBanner {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Version)
    $os = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif ($IsLinux) { 'Linux' } else { 'unknown' }
    Write-CABColor Cyan ''
    Write-CABColor Cyan '  ChannelAssist developer onboarding'
    Write-CABColor DarkGray "  ca-bootstrap v$Version on PowerShell $($PSVersionTable.PSVersion) ($os)"
    Write-Host ''
}

# Functions exported automatically when this file is dot-sourced.
