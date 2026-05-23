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
        $script:foldersManifest = [pscustomobject]@{
            folders = @(
                [pscustomobject]@{ path = 'ca-tools';      optional = $false }
                [pscustomobject]@{ path = 'ca-docs';       optional = $false }
                [pscustomobject]@{ path = 'ca-platform';   optional = $false }
                [pscustomobject]@{ path = 'cm-product';    optional = $false }
                [pscustomobject]@{ path = 'ca-training';   optional = $false }
                [pscustomobject]@{ path = 'ca-experiments'; optional = $true;  renamed_from = 'experiments' }
                [pscustomobject]@{ path = 'ca-work-dirs';  optional = $false }
            )
        }
        Mock -CommandName Read-CABManifest -MockWith {
            if ($Path -like '*manifest/folders.yaml') { return $script:foldersManifest }
            return [pscustomobject]@{ groups = @() }
        }
        Mock -CommandName Get-CABToolReport -MockWith { @() }
        Mock -CommandName Test-CABRepoCloned -MockWith { 'matches' }

        New-Item -ItemType Directory -Path $script:tmpWs -Force | Out-Null
        # Pre-create every required folder + ca-work-dirs so the existing
        # `folders` check doesn't fail and mask the new rename check.
        foreach ($p in 'ca-tools','ca-docs','ca-platform','cm-product','ca-training','ca-work-dirs') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $p) -Force | Out-Null
        }
        # Supply WorkspacePath directly in the context so doctor bypasses the
        # journal-state lookup entirely. On Windows, Pester's in-memory
        # $Script:CABJournalState can persist stale entries from earlier test
        # cases that pointed at now-deleted temp dirs; those stale entries
        # would resolve $workspace to a non-existent path, causing Test-Path
        # to return $false and every workspace-gated check to be silently
        # skipped. Also keep the env-var as a belt-and-suspenders fallback.
        $env:CA_BOOTSTRAP_WORKSPACE = $script:tmpWs
        $script:ctx = @{ RepoRoot = $script:repoRoot; WorkspacePath = $script:tmpWs }
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
        $hit.details | Should -Match 'Cannot enumerate'
    }

    It 'fails when the legacy rename path exists as a non-directory' {
        Set-Content -Path (Join-Path $script:tmpWs 'experiments') -Value 'not a directory' -Encoding utf8

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'fail'
        $hit.details | Should -Match 'not a directory'
    }

    It 'fails when the new rename path exists as a non-directory' {
        Set-Content -Path (Join-Path $script:tmpWs 'ca-experiments') -Value 'not a directory' -Encoding utf8

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hit = $checks | Where-Object { $_.id -eq 'folder-rename:experiments' }
        $hit.status | Should -Be 'fail'
        $hit.details | Should -Match 'not a directory'
    }
}

