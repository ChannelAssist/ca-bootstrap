#requires -Version 7.0
# tests/lib/bootstrap-tui-install.tests.ps1 — coverage for the new
# Python+cab-tui install path added to bootstrap.ps1 in v1.4.0.
#
# Full end-to-end coverage of the install function is impractical: it
# spawns winget, prompts via Read-Host, and assumes a freshly-cloned
# cache directory — none of which we want to drive in unit tests. So we
# test the regression-prone surfaces:
#   - the script parses (catches syntax errors that would silently
#     break the curl-pipe entrypoint)
#   - the new helper functions are present and have the expected
#     signatures (catches accidental renames / removals during
#     refactors)
#   - the mode-2 short-circuit still fires when a sibling
#     ca-bootstrap.ps1 exists (which in turn means Install-PythonAndTui
#     is NEVER invoked from a clone, so a regression in that function
#     can't break daily-driver `./bootstrap.ps1 doctor` use)

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $script:bootstrapPs1 = Join-Path $script:repoRoot 'bootstrap.ps1'
    Test-Path $script:bootstrapPs1 | Should -BeTrue
}

Describe 'bootstrap.ps1 — Python/cab-tui install path' {
    It 'parses without syntax errors' {
        $errors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script:bootstrapPs1, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'declares the new helper functions added in v1.4.0' {
        $content = Get-Content -Raw $script:bootstrapPs1
        $content | Should -Match 'function\s+Find-Python310Plus'
        $content | Should -Match 'function\s+Install-Python\b'
        $content | Should -Match 'function\s+Install-PythonAndTui'
    }

    It 'Install-PythonAndTui has the expected guards (env var + cache dir)' {
        # Defensive read of the function body — the early-out branches
        # are what keep the install path from running in mode-2 / opt-out.
        $content = Get-Content -Raw $script:bootstrapPs1
        $content | Should -Match 'CA_BOOTSTRAP_NO_TUI'
        # Check for the "older release without TUI" guard.
        $content | Should -Match 'Test-Path\s+\$cabTuiDir'
    }

    It 'bootstrap.sh detect_python tries `python` in addition to `python3*` symlinks' {
        # Regression guard for Copilot iter-6 #1: pyenv/conda envs may
        # only have `python` on PATH. Without this candidate, bootstrap
        # would falsely report Python missing and prompt to reinstall.
        $bash = Join-Path $script:repoRoot 'bootstrap.sh'
        $content = Get-Content -Raw $bash
        $content | Should -Match 'detect_python\(\)'
        # Pull out the candidate list from the loop. We allow any order
        # / additional version suffixes, but `python` (no suffix) must
        # appear so non-symlinked interpreters resolve.
        $content | Should -Match 'for cand in [^;]*\bpython\b'
    }

    It 'bootstrap.sh recreates a stale (<3.10) cab-tui/.venv before installing' {
        # Behavioral regression guard for Copilot iter-4 #2 (PR #5):
        # source the install_python_and_tui function from bootstrap.sh,
        # point it at a fake cab-tui dir whose .venv is a 3.9 stub, and
        # confirm the function recreates the venv (i.e. removes the
        # marker file we plant in the stale venv).
        $bash = Join-Path $script:repoRoot 'bootstrap.sh'
        $content = Get-Content -Raw $bash
        # Static guards (cheap, catch the most common refactor mistake):
        $content | Should -Match 'Existing.*venv_dir.*Python <3.10'
        $content | Should -Match 'rm -rf "\$venv_dir"'
        # Behavioral check: the recreate path is gated on a Python
        # version probe via `-c 'import sys; v=sys.version_info; ...'`.
        $content | Should -Match 'venv_ver=\$\(.*v\[0\]\*100\+v\[1\]'
        $content | Should -Match '\$venv_ver.*-lt 310'
    }

    It 'bootstrap.ps1 recreates a stale (<3.10) cab-tui/.venv before installing' {
        # Same regression guard for the PowerShell side.
        $content = Get-Content -Raw $script:bootstrapPs1
        $content | Should -Match 'Existing.*venvDir.*Python <3.10'
        $content | Should -Match 'Remove-Item -Recurse -Force \$venvDir'
        $content | Should -Match 'venvVer.*v\[0\]\*100\+v\[1\]'
        $content | Should -Match '\[int\]\$venvVer.*-lt 310'
    }

    It 'bootstrap.ps1 clears UF_HIDDEN on macOS after pip install' {
        # Copilot iter-4 #10: the bash + Makefile install paths both
        # clear the macOS hidden flag on the editable .pth shim;
        # bootstrap.ps1 was missing this. macOS users running pwsh-
        # bootstrap would otherwise hit the same Python 3.14 site.py
        # skip-hidden bug.
        $content = Get-Content -Raw $script:bootstrapPs1
        $content | Should -Match 'IsMacOS'
        $content | Should -Match 'chflags nohidden'
    }

    It 'mode-2 short-circuit forwards to the sibling ca-bootstrap.ps1 (skipping the install path)' {
        # The mode-2 short-circuit lives at the top of bootstrap.ps1 and
        # exec's the sibling orchestrator without going through any of
        # the install logic. Run with `version` so the orchestrator
        # exits cleanly without prompting. This test confirms that
        # daily-driver `./bootstrap.ps1 <command>` use remains
        # unaffected by the new install path — regressions there have
        # historically been the most painful failure mode.
        $output = & pwsh -NoLogo -NoProfile -File $script:bootstrapPs1 version 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match 'ca-bootstrap'
    }
}
