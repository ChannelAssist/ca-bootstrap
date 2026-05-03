#requires -Version 7.0
# commands/doctor.ps1 — diagnostic-only run.
#
# Phase 1 stub. Phase 8 fills in real detection logic against
# every step's Test function.

function Invoke-CABCommandDoctor {
    [CmdletBinding()]
    param([hashtable]$Context = @{})
    Write-CABHeader 'ca-bootstrap doctor'
    Write-CABStatus -Status info -Message 'Doctor is a phase-8 deliverable. Phase 1 stub runs no checks.'
    Write-Host ''
    Write-Host "  Once implemented, doctor will run every step's detection function and"
    Write-Host '  produce a green/yellow/red report. See docs/commands.md for the planned'
    Write-Host '  output formats (--json, --summary, --target).'
    Write-Host ''
    return 0
}

# Function exported automatically when this file is dot-sourced.
