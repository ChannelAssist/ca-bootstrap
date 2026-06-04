#requires -Version 7.0
# tests/lib/manifest-drift.tests.ps1 — catches manifest tool-regex drift.
#
# When a tool's --version output format changes (e.g. dotnet 11 ships and
# `dotnet --list-sdks` no longer matches `^(10\.\d+\.\d+)`), Test-CABTool
# starts reporting "fail" for an installed tool. This test runs detection
# against every tool in the manifest and asserts that any tool present on
# the runner produces ok/warn/na — never fail/error from regex drift.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $repoRoot 'lib/ui.ps1')
    . (Join-Path $repoRoot 'lib/yaml.ps1')
    . (Join-Path $repoRoot 'lib/journal.ps1')
    . (Join-Path $repoRoot 'lib/platform.ps1')
    . (Join-Path $repoRoot 'lib/tools.ps1')
}

Describe 'manifest/tools.yaml regex sanity' {
    It 'all installed tools detect cleanly (no fail/error from regex drift)' {
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $manifest = Read-CABManifest -Path (Join-Path $repoRoot 'manifest/tools.yaml')
        $allTools = @($manifest.required) + @($manifest.optional)
        $report = New-Object System.Collections.ArrayList
        foreach ($tool in $allTools) {
            if (-not $tool.check.cmd) { continue }
            $exe = ($tool.check.cmd -split '\s+', 2)[0]
            if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { continue }
            $r = Test-CABTool -Tool $tool
            if ($r.status -notin 'ok','warn','na') {
                [void]$report.Add("$($tool.id): status=$($r.status), details=$($r.details)")
            }
        }
        $report.Count | Should -Be 0 -Because "drifted regex(es) detected:`n$($report -join "`n")"
    }
}
