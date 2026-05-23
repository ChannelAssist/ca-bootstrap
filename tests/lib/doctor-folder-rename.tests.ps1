#requires -Version 7.0
# tests/lib/doctor-folder-rename.tests.ps1 — doctor's new folder-rename
# check driven by `renamed_from:` in folders.yaml. Covers all 5 rows of
# the decision table in the spec.

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/ui.ps1')
    . (Join-Path $script:repoRoot 'lib/yaml.ps1')
    . (Join-Path $script:repoRoot 'lib/journal.ps1')
    . (Join-Path $script:repoRoot 'commands/doctor.ps1')
}

Describe 'Doctor — folder-rename check' {
    BeforeEach {
        $script:tmpWs = Join-Path ([System.IO.Path]::GetTempPath()) "cab-doctor-rename-$(Get-Random)"
        $script:tmpState = Join-Path ([System.IO.Path]::GetTempPath()) "cab-doctor-state-$(Get-Random)"
        $env:CA_BOOTSTRAP_STATE = $script:tmpState
        Reset-CABJournalState

        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
        # Pre-create every required folder + ca-work-dirs so the existing
        # `folders` check doesn't fail and mask the new rename check.
        foreach ($p in 'ca-tools','ca-docs','ca-platform','cm-product','ca-training','ca-work-dirs') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $p) -Force | Out-Null
        }
        # Force the workspace path so doctor doesn't read from the journal.
        $env:CA_BOOTSTRAP_WORKSPACE = $script:tmpWs
        $script:ctx = @{ RepoRoot = $script:repoRoot }
    }
    AfterEach {
        foreach ($p in @($script:tmpWs, $script:tmpState)) {
            if ($p -and (Test-Path $p)) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
        }
        Remove-Item Env:CA_BOOTSTRAP_WORKSPACE -ErrorAction SilentlyContinue
        Remove-Item Env:CA_BOOTSTRAP_STATE -ErrorAction SilentlyContinue
    }

    It 'omits the check when neither legacy nor new exists' {
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        # No legacy folder + no new folder → no check entry should be emitted at all.
        $hit | Should -BeNullOrEmpty -Because 'no legacy folder present: no check entry should be emitted'
    }

    It 'is silent when only ca-experiments exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit | Should -BeNullOrEmpty -Because 'only the new path exists: no check entry should be emitted'
    }

    It 'warns when only legacy experiments/ exists' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'experiments') -Force | Out-Null
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit | Should -Not -BeNullOrEmpty
        $hit.status | Should -Be 'warn'
        $hit.fix | Should -Be 'repair --target folder-renames'
    }

    It 'warns when both exist and both are empty' {
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'experiments')    -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null
        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'warn'
    }

    It 'fails when both exist and at least one has contents' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        $new    = Join-Path $script:tmpWs 'ca-experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null
        New-Item -ItemType Directory -Path $new    -Force | Out-Null
        Set-Content -Path (Join-Path $legacy 'a.txt') -Value 'x' -Encoding utf8
        Set-Content -Path (Join-Path $new    'b.txt') -Value 'y' -Encoding utf8

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'fail'
        $hit.details | Should -Match 'manual'
    }

    It 'fails when folder content enumeration errors' {
        $legacy = Join-Path $script:tmpWs 'experiments'
        New-Item -ItemType Directory -Path $legacy -Force | Out-Null

        Mock -CommandName Get-ChildItem -ParameterFilter { $Path -eq $legacy } -MockWith {
            throw 'access denied'
        }

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'fail'
        $hit.details | Should -Match 'Unable to inspect folder contents'
    }
}
