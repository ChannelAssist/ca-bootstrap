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
            # Use *folders.yaml (no path separator) so the match works on both
            # Windows (backslash) and Unix (forward slash) path separators.
            if ($Path -like '*folders.yaml') { return $script:foldersManifest }
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

    It 'surfaces every predecessor in a renamed_from list when each lingers on disk' {
        # PR #82 cycle-1 review pinned: the legacy folder-rename check
        # used to cast renamed_from as a scalar via [string]$f.renamed_from,
        # which produces "experiments older-experiments" (space-joined)
        # for a list. The chain-aware rewrite must iterate the full list
        # via Get-CABFolderRenamedFrom and emit one check per predecessor
        # found on disk.
        $script:foldersManifest = [pscustomobject]@{
            folders = @(
                [pscustomobject]@{ path = 'ca-tools';      optional = $false }
                [pscustomobject]@{ path = 'ca-docs';       optional = $false }
                [pscustomobject]@{ path = 'ca-platform';   optional = $false }
                [pscustomobject]@{ path = 'cm-product';    optional = $false }
                [pscustomobject]@{ path = 'ca-training';   optional = $false }
                [pscustomobject]@{
                    path         = 'ca-experiments'
                    optional     = $true
                    renamed_from = @('experiments','older-experiments')  # list, not scalar
                }
                [pscustomobject]@{ path = 'ca-work-dirs';  optional = $false }
            )
        }
        # Both legacies on disk PLUS the new path; new is empty so the
        # folder-rename cleanup should report a warn check for EACH
        # legacy, not just the first.
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'experiments') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'older-experiments') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $hits = @($checks | Where-Object { $_.id -like 'folder-rename:*' })
        # Two predecessors on disk → two cleanup checks.
        $hits.Count | Should -Be 2
        ($hits | ForEach-Object { $_.id }) | Should -Contain 'folder-rename:experiments'
        ($hits | ForEach-Object { $_.id }) | Should -Contain 'folder-rename:older-experiments'
        # Both should be warns (legacy exists alongside an empty new path).
        ($hits | ForEach-Object { $_.status }) | Should -Be @('warn','warn')
    }

    It 'classifies the folders check as fail (collision) when a required path exists as a regular file' {
        # PR #82 cycle-3 review pinned: a required-folder path that
        # exists as a regular file used to land in the "missing" set
        # via -PathType Container, and if a predecessor directory
        # existed too the doctor `folders` check downgraded to warn
        # with a `renames` action — but Invoke-CABStep50 would bail
        # with "exists but is not a directory" before any rename
        # could fire. Doctor and step diverged on a blocking collision.
        #
        # Required-path collisions are now detected BEFORE the
        # predecessor walk and reported as fail with a `collisions`
        # field. No `fix` recipe is advertised — the non-directory
        # must be resolved manually.
        $script:foldersManifest = [pscustomobject]@{
            folders = @(
                [pscustomobject]@{ path = 'ca-tools';      optional = $false }
                [pscustomobject]@{ path = 'ca-docs';       optional = $false }
                [pscustomobject]@{ path = 'ca-platform';   optional = $false }
                [pscustomobject]@{ path = 'cm-product';    optional = $false }
                [pscustomobject]@{ path = 'ca-training';   optional = $false }
                [pscustomobject]@{
                    path         = 'ca-prototypes'
                    optional     = $false
                    renamed_from = 'ca-experiments'
                }
                [pscustomobject]@{ path = 'ca-work-dirs';  optional = $false }
            )
        }
        # Seed: every other required folder as a directory; ca-prototypes
        # as a regular file (collision); ca-experiments as a directory
        # so a predecessor would tempt the OLD code to render a rename.
        foreach ($p in 'ca-tools','ca-docs','ca-platform','cm-product','ca-training','ca-work-dirs') {
            New-Item -ItemType Directory -Path (Join-Path $script:tmpWs $p) -Force | Out-Null
        }
        New-Item -ItemType Directory -Path (Join-Path $script:tmpWs 'ca-experiments') -Force | Out-Null
        Set-Content -Path (Join-Path $script:tmpWs 'ca-prototypes') -Value 'not a directory' -Encoding utf8

        $checks = Invoke-CABDoctorCheck -Context $script:ctx
        $folders = $checks | Where-Object { $_.id -eq 'folders' }
        $folders.status | Should -Be 'fail'
        $folders.details | Should -Match 'collision'
        $folders.details | Should -Match 'ca-prototypes'
        # MUST NOT advertise `repair --target folders` for a collision —
        # the step would fail before fixing anything.
        $folders.PSObject.Properties.Name | Should -Not -Contain 'fix'
        # MUST NOT report this as a pending rename either.
        $folders.details | Should -Not -Match 'ca-experiments\s*→'
    }
}

