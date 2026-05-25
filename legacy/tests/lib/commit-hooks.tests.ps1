#requires -Version 7.0
# tests/lib/commit-hooks.tests.ps1 — unit tests for lib/commit-hooks.ps1.
#
# Covers the pure helper functions exposed by lib/commit-hooks.ps1 that
# back scripts/install-commit-hooks.ps1. The script itself is exercised
# via dry-run integration tests in tests/regression/ (out of scope here).

BeforeAll {
    $script:repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    . (Join-Path $script:repoRoot 'lib/commit-hooks.ps1')

    # Per-test scratch dir. We use it for fixture repos.
    $script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cab-hooks-test-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:tmpRoot -Force | Out-Null
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path $script:tmpRoot)) {
        Remove-Item -Recurse -Force $script:tmpRoot
    }
}

Describe 'Test-CABHasCommitlintConfig' {
    It 'detects commitlint.config.js' {
        $dir = Join-Path $script:tmpRoot ("cfg-js-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'commitlint.config.js') -Value 'module.exports = {};'
        Test-CABHasCommitlintConfig -RepoDir $dir | Should -BeTrue
    }

    It 'detects each modern variant (.{js,mjs,cjs,ts})' {
        foreach ($name in @('commitlint.config.mjs', 'commitlint.config.cjs', 'commitlint.config.ts')) {
            $dir = Join-Path $script:tmpRoot ("cfg-" + ($name -replace '\.', '-'))
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -Path (Join-Path $dir $name) -Value '// stub'
            Test-CABHasCommitlintConfig -RepoDir $dir | Should -BeTrue -Because "Variant $name should be detected"
        }
    }

    It 'detects each .commitlintrc variant (json/yml/yaml/cjs/mjs/ts)' {
        foreach ($name in @('.commitlintrc', '.commitlintrc.json', '.commitlintrc.yml', '.commitlintrc.yaml',
                            '.commitlintrc.cjs', '.commitlintrc.mjs', '.commitlintrc.ts')) {
            $dir = Join-Path $script:tmpRoot ("rc-" + ($name -replace '\.', '-'))
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Set-Content -Path (Join-Path $dir $name) -Value '{}'
            Test-CABHasCommitlintConfig -RepoDir $dir | Should -BeTrue -Because "Variant $name should be detected"
        }
    }

    It 'detects a commitlint key in package.json' {
        $dir = Join-Path $script:tmpRoot ("pkg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'package.json') -Value '{ "name": "x", "commitlint": { "extends": ["@commitlint/config-conventional"] } }'
        Test-CABHasCommitlintConfig -RepoDir $dir | Should -BeTrue
    }

    It 'returns false for a directory with no commitlint config' {
        $dir = Join-Path $script:tmpRoot ("none-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Test-CABHasCommitlintConfig -RepoDir $dir | Should -BeFalse
    }

    It 'returns false on a malformed package.json (does not throw)' {
        $dir = Join-Path $script:tmpRoot ("bad-pkg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir 'package.json') -Value '{ this is not valid json'
        { Test-CABHasCommitlintConfig -RepoDir $dir } | Should -Not -Throw
        Test-CABHasCommitlintConfig -RepoDir $dir | Should -BeFalse
    }
}

Describe 'Test-CABHookIsOurs' {
    It 'returns true for a hook with the marker line' {
        $hook = Join-Path $script:tmpRoot ("ours-" + [guid]::NewGuid().ToString('N'))
        Set-Content -Path $hook -Value (Get-CABCommitMsgHookBody)
        Test-CABHookIsOurs -HookPath $hook | Should -BeTrue
    }

    It 'handles CRLF line endings correctly' {
        # This is the bug Copilot caught: single-quoted `'`r'` doesn't escape.
        # Write a CRLF-line-ended copy of our hook body and confirm we still
        # detect the marker.
        $hook = Join-Path $script:tmpRoot ("crlf-" + [guid]::NewGuid().ToString('N'))
        $body = Get-CABCommitMsgHookBody
        $crlfBody = $body -replace "`n", "`r`n"
        Set-Content -Path $hook -Value $crlfBody -NoNewline
        Test-CABHookIsOurs -HookPath $hook | Should -BeTrue
    }

    It 'returns false for a foreign hook' {
        $hook = Join-Path $script:tmpRoot ("foreign-" + [guid]::NewGuid().ToString('N'))
        Set-Content -Path $hook -Value "#!/bin/sh`necho hi"
        Test-CABHookIsOurs -HookPath $hook | Should -BeFalse
    }

    It 'returns false for a missing hook' {
        Test-CABHookIsOurs -HookPath (Join-Path $script:tmpRoot 'does-not-exist') | Should -BeFalse
    }
}

Describe 'Test-CABHookInvokesCommitlint' {
    It 'returns true for our installed hook' {
        $hook = Join-Path $script:tmpRoot ("ic-ours-" + [guid]::NewGuid().ToString('N'))
        Set-Content -Path $hook -Value (Get-CABCommitMsgHookBody)
        Test-CABHookInvokesCommitlint -HookPath $hook | Should -BeTrue
    }

    It 'returns true for a different hook that invokes commitlint' {
        $hook = Join-Path $script:tmpRoot ("ic-foreign-" + [guid]::NewGuid().ToString('N'))
        Set-Content -Path $hook -Value "#!/bin/sh`nnpx commitlint --edit `$1"
        Test-CABHookInvokesCommitlint -HookPath $hook | Should -BeTrue
    }

    It 'returns false for a hook that does NOT mention commitlint' {
        $hook = Join-Path $script:tmpRoot ("ic-none-" + [guid]::NewGuid().ToString('N'))
        Set-Content -Path $hook -Value "#!/bin/sh`necho hello"
        Test-CABHookInvokesCommitlint -HookPath $hook | Should -BeFalse
    }
}

Describe 'Get-CABRelativePath' {
    It 'returns "." when path equals base' {
        $b = Join-Path $script:tmpRoot 'workspace'
        Get-CABRelativePath -Path $b -BasePath $b | Should -Be '.'
    }

    It 'strips the base prefix for a descendant' {
        $b = Join-Path $script:tmpRoot 'workspace'
        $p = Join-Path $b (Join-Path 'group' 'repo')
        $r = Get-CABRelativePath -Path $p -BasePath $b
        $r | Should -Match 'group[\\/]repo$'
    }

    It 'returns absolute path unchanged when not a descendant of base' {
        $b = Join-Path $script:tmpRoot 'workspace'
        $p = Join-Path $script:tmpRoot 'unrelated/thing'
        Get-CABRelativePath -Path $p -BasePath $b | Should -Be $p
    }

    It 'does NOT consult the current working directory (regression for Copilot review on PR #57)' {
        # The original implementation used `Resolve-Path -Relative`, which
        # uses the caller's CWD as the anchor. Our replacement must produce
        # the same answer regardless of where we cd to.
        $b = Join-Path $script:tmpRoot 'cwd-test-workspace'
        $p = Join-Path $b 'group/repo'
        New-Item -ItemType Directory -Force -Path $p | Out-Null

        Push-Location $script:tmpRoot
        try {
            $fromTmp = Get-CABRelativePath -Path $p -BasePath $b
        } finally {
            Pop-Location
        }
        Push-Location ([System.IO.Path]::GetTempPath())
        try {
            $fromSysTemp = Get-CABRelativePath -Path $p -BasePath $b
        } finally {
            Pop-Location
        }
        $fromTmp | Should -Be $fromSysTemp
    }
}

Describe 'Get-CABCommitlintRepos' {
    BeforeAll {
        $script:wsRoot = Join-Path $script:tmpRoot ("ws-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:wsRoot | Out-Null
    }

    It 'discovers a flat-layout repo (workspace/repo/.git)' {
        $repo = Join-Path $script:wsRoot 'flat-repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git') | Out-Null
        $found = @(Get-CABCommitlintRepos -WorkspacePath $script:wsRoot)
        $found | Should -Contain $repo
    }

    It 'discovers a 2-level layout repo (workspace/group/repo/.git)' {
        $repo = Join-Path $script:wsRoot 'group-2/two-level-repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git') | Out-Null
        $found = @(Get-CABCommitlintRepos -WorkspacePath $script:wsRoot)
        $found | Should -Contain $repo
    }

    It 'skips a directory that has no .git anywhere' {
        $emptyGroup = Join-Path $script:wsRoot 'empty-group'
        $emptySub = Join-Path $emptyGroup 'subdir-not-a-repo'
        New-Item -ItemType Directory -Force -Path $emptySub | Out-Null
        $found = @(Get-CABCommitlintRepos -WorkspacePath $script:wsRoot)
        $found | Should -Not -Contain $emptySub
        $found | Should -Not -Contain $emptyGroup
    }
}
