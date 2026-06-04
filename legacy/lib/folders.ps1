#requires -Version 7.0
# lib/folders.ps1 — folder manifest helpers.
#
# Currently exposes one helper: Get-CABFolderRenamedFrom, which
# normalises a folders.yaml entry's `renamed_from:` field into an
# ordered list of predecessor paths (most-recent first).
#
# A folder entry may declare its rename history in three shapes:
#
#   - path: ca-prototypes               # no history
#
#   - path: ca-prototypes               # single predecessor (scalar)
#     renamed_from: ca-experiments
#
#   - path: ca-prototypes               # multi-step history (list)
#     renamed_from:                     # most recent → oldest
#       - ca-experiments
#       - experiments
#
# Doctor walks every predecessor when reporting drift so an operator
# who skipped the first migration still sees a path forward; repair
# walks the same list and renames the most-recent existing
# predecessor to the current path.

function Get-CABFolderRenamedFrom {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Folder
    )
    if (-not $Folder) { return @() }

    # ConvertFrom-Yaml returns OrderedDictionary for mappings; both
    # PSCustomObject and Hashtable can also appear when callers build
    # entries in-process (tests, manifest-edit). Probe each shape.
    $value = $null
    if ($Folder -is [System.Collections.IDictionary]) {
        if ($Folder.Contains('renamed_from')) { $value = $Folder['renamed_from'] }
    } elseif ($Folder.PSObject.Properties['renamed_from']) {
        $value = $Folder.PSObject.Properties['renamed_from'].Value
    }

    if ($null -eq $value) { return @() }
    if ($value -is [string]) {
        $trimmed = $value.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { return @() }
        return @($trimmed)
    }
    # Array / list — coerce to string[], drop nulls/empties, trim.
    # Returned as a plain array (no comma-wrap) so callers can use the
    # idiomatic `foreach ($p in @(Get-CABFolderRenamedFrom …))` —
    # `,$list` would defeat the outer `@()` and yield a single
    # nested-array element.
    $list = @()
    foreach ($item in @($value)) {
        if ($null -eq $item) { continue }
        $s = ([string]$item).Trim()
        if ([string]::IsNullOrEmpty($s)) { continue }
        $list += $s
    }
    return $list
}
