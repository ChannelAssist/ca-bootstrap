#requires -Version 7.0
# lib/commit-hooks.ps1 — helpers for scripts/install-commit-hooks.ps1.
#
# Extracted into lib/ so the script and its Pester tests can both
# dot-source the same definitions, matching the existing ca-bootstrap
# pattern (see lib/ui.ps1, lib/yaml.ps1, lib/journal.ps1 etc.).

# The shell hook body. Written to .git/hooks/commit-msg in each
# matched repo. `--no-install` makes npx fail clearly if commitlint
# isn't already in node_modules (rather than triggering an unbounded
# `npx install` on every commit).
$script:CABCommitMsgHookBody = @'
#!/usr/bin/env sh
# Installed by ca-bootstrap/scripts/install-commit-hooks.ps1
# Runs commitlint locally so a non-conforming header (e.g. >72 chars)
# is rejected at `git commit` time, not at PR CI time.
# Skips if npx isn't on PATH (graceful — keep the commit flow working
# even on a partial dev-env setup).
if ! command -v npx >/dev/null 2>&1; then
  echo "[commit-msg] npx not on PATH; skipping commitlint check." >&2
  exit 0
fi
exec npx --no-install commitlint --edit "$1"
'@

# Marker line embedded in the hook body so we can detect our own
# installs vs. foreign ones on subsequent runs.
$script:CABCommitMsgHookMarker = 'Installed by ca-bootstrap/scripts/install-commit-hooks\.ps1'

function Test-CABHasCommitlintConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoDir
    )
    # All commitlint config filenames the upstream tool resolves
    # (https://commitlint.js.org/reference/configuration.html#config-file).
    foreach ($name in @(
        'commitlint.config.js',
        'commitlint.config.mjs',
        'commitlint.config.cjs',
        'commitlint.config.ts',
        '.commitlintrc',
        '.commitlintrc.js',
        '.commitlintrc.mjs',
        '.commitlintrc.cjs',
        '.commitlintrc.ts',
        '.commitlintrc.json',
        '.commitlintrc.yml',
        '.commitlintrc.yaml'
    )) {
        if (Test-Path (Join-Path $RepoDir $name)) { return $true }
    }
    # Also check package.json for a `commitlint` key.
    $pkg = Join-Path $RepoDir 'package.json'
    if (Test-Path $pkg) {
        try {
            $obj = Get-Content $pkg -Raw | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'commitlint') {
                return $true
            }
        } catch {
            # Malformed package.json — ignore, don't crash the sweep.
        }
    }
    return $false
}

function Test-CABHookIsOurs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HookPath
    )
    if (-not (Test-Path $HookPath)) { return $false }
    $content = Get-Content $HookPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return $false }
    # Normalize CRLF → LF before matching. Single-quoted '\r' is a regex
    # pattern that DOES match a carriage return; the previous code used
    # `'`r'` which in single quotes is just the literal two-character
    # string "`r" (backtick + r) and didn't strip anything.
    $normalized = $content -replace '\r', ''
    return $normalized -match $script:CABCommitMsgHookMarker
}

function Test-CABHookInvokesCommitlint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HookPath
    )
    if (-not (Test-Path $HookPath)) { return $false }
    $content = Get-Content $HookPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return $false }
    return $content -match 'commitlint'
}

function Get-CABCommitlintRepos {
    # Yields every git repo under $WorkspacePath that has a commitlint
    # config. Handles both the wizard's default 2-level layout
    # (<workspace>/<group>/<repo>) AND a flat layout where clones sit
    # directly under <workspace> — for each candidate dir, if it's a git
    # repo we yield it; otherwise we recurse one more level. Stops at
    # depth 2 (the wizard's convention).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath
    )
    Get-ChildItem -Path $WorkspacePath -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $top = $_.FullName
            if (Test-Path (Join-Path $top '.git')) {
                # Flat layout: $top IS a repo.
                $top
            } else {
                # Two-level layout: scan one level deeper.
                Get-ChildItem -Path $top -Directory -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName '.git') } |
                    ForEach-Object { $_.FullName }
            }
        }
}

function Get-CABRelativePath {
    # Compute a path relative to $BasePath without consulting the CWD.
    # `Resolve-Path -Relative` uses the caller's working directory,
    # which produces unhelpful `../../...` chains when the script is
    # run from a directory unrelated to the workspace (the common case
    # — `make install-commit-hooks` is invoked from the ca-bootstrap
    # repo root, scanning ~/ChannelAssist/…).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BasePath
    )
    $p = $Path.TrimEnd([char]'/', [char]'\')
    $b = $BasePath.TrimEnd([char]'/', [char]'\')
    if ($p.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    if ($p.StartsWith($b + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($b + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $p.Substring($b.Length).TrimStart([char]'/', [char]'\')
    }
    return $p
}

function Get-CABCommitMsgHookBody {
    # Returns the canonical shell body installed at .git/hooks/commit-msg.
    return $script:CABCommitMsgHookBody
}
