#requires -Version 7.0
# tests/regression/v1.0.2-bootstrap-recovery.tests.ps1
#
# Bug fixed: d40dea1 — bootstrap.ps1's `git pull` exited non-zero when the
# user's global .gitconfig was malformed, but the script ignored the exit
# code and ran the stale cached version of ca-bootstrap. The fix makes the
# script check $LASTEXITCODE after `git fetch` and refresh the cache from
# scratch on failure.
#
# Properties under test:
#   1. When the cache is corrupt, bootstrap.ps1 detects it and re-clones.
#   2. When git itself fails (any reason), bootstrap.ps1 does NOT silently
#      continue with a stale cache — it either re-clones or exits non-zero.
# These two together bracket the original bug regardless of fix mechanism.

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:bootstrapPs1 = Join-Path $repoRoot 'bootstrap.ps1'
}

Describe 'bootstrap.ps1 — cache recovery (regression v1.0.2)' {
    BeforeEach {
        # Set up a fixture "remote" that bootstrap.ps1 will clone from.
        # We make a bare-ish local repo that just contains ca-bootstrap.ps1
        # so the bootstrap completes its handoff without doing real work.
        $script:fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cab-boot-$(Get-Random)"
        $script:fixtureRemote = Join-Path $script:fixtureRoot 'fake-remote'
        $script:fixtureCache  = Join-Path $script:fixtureRoot 'cache'
        [void](New-Item -ItemType Directory -Path $script:fixtureRemote -Force)

        # Initialize the fake remote and add a stub ca-bootstrap.ps1 that
        # just prints "stub-fired" and exits 0 — so we can verify which
        # code path the bootstrap took.
        Push-Location $script:fixtureRemote
        try {
            & git init --quiet -b main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'Test' 2>&1 | Out-Null
            $stubContent = @'
param([Parameter(ValueFromRemainingArguments=$true)]$Args)
Write-Host "stub-fired"
exit 0
'@
            Set-Content -Path 'ca-bootstrap.ps1' -Value $stubContent
            & git add . 2>&1 | Out-Null
            & git commit --quiet -m 'init' 2>&1 | Out-Null
        } finally { Pop-Location }
    }
    AfterEach {
        if ($script:fixtureRoot -and (Test-Path $script:fixtureRoot)) {
            Remove-Item -Recurse -Force $script:fixtureRoot -ErrorAction SilentlyContinue
        }
    }

    It 'self-heals when the cache .git directory is corrupted' {
        # First run: clone the cache from the fixture remote.
        $env:CA_BOOTSTRAP_REPO  = $script:fixtureRemote
        $env:CA_BOOTSTRAP_REF   = 'main'
        $env:CA_BOOTSTRAP_CACHE = $script:fixtureCache
        try {
            $out1 = & pwsh -NoLogo -File $script:bootstrapPs1 2>&1 | Out-String
            ($out1 -match 'stub-fired') | Should -BeTrue -Because 'first run should clone and exec the stubbed orchestrator'

            # Now corrupt the cache by replacing .git/HEAD with garbage.
            Set-Content -Path (Join-Path $script:fixtureCache '.git/HEAD') -Value 'this-is-not-valid-git'

            # Second run should detect failure and re-clone.
            $out2 = & pwsh -NoLogo -File $script:bootstrapPs1 2>&1 | Out-String
            ($out2 -match 'stub-fired') | Should -BeTrue -Because 'after corruption, bootstrap.ps1 must re-clone and complete (the v1.0.2 fix)'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_REPO, Env:CA_BOOTSTRAP_REF, Env:CA_BOOTSTRAP_CACHE -ErrorAction SilentlyContinue
        }
    }

    It 'does not silently continue with stale cache when git is broken' {
        # Set up a normal cache first, then sabotage git.
        $env:CA_BOOTSTRAP_REPO  = $script:fixtureRemote
        $env:CA_BOOTSTRAP_REF   = 'main'
        $env:CA_BOOTSTRAP_CACHE = $script:fixtureCache

        try {
            # Real bootstrap to populate cache.
            & pwsh -NoLogo -File $script:bootstrapPs1 2>&1 | Out-Null

            # Stub `git` that always exits 1.
            $stubBin = Join-Path $script:fixtureRoot 'badbin'
            [void](New-Item -ItemType Directory -Path $stubBin -Force)
            $stubGit = Join-Path $stubBin 'git'
            Set-Content -Path $stubGit -Value "#!/usr/bin/env bash`nexit 1`n"
            & chmod +x $stubGit

            # Sentinel so we can detect a silent stale-cache execution.
            Set-Content -Path (Join-Path $script:fixtureCache 'ca-bootstrap.ps1') `
                -Value "Write-Host 'stale-cache-was-used'; exit 0"

            # macOS pwsh rebuilds `$env:PATH` from /etc/paths at startup,
            # so the parent's PATH override is lost. Set PATH inside the
            # spawned pwsh via -NoProfile + an inline command.
            $cmd = "`$env:PATH = '$stubBin' + [IO.Path]::PathSeparator + `$env:PATH; & '$($script:bootstrapPs1)'"
            $out = & pwsh -NoLogo -NoProfile -Command $cmd 2>&1 | Out-String

            ($out -match 'stale-cache-was-used') | Should -BeFalse `
                -Because 'bootstrap.ps1 must not silently run stale cache when git fails (v1.0.2 bug class)'
        } finally {
            Remove-Item Env:CA_BOOTSTRAP_REPO, Env:CA_BOOTSTRAP_REF, Env:CA_BOOTSTRAP_CACHE -ErrorAction SilentlyContinue
        }
    }
}
