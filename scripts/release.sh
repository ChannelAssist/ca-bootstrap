#!/usr/bin/env bash
# scripts/release.sh — cut a ca-bootstrap release.
#
# Invoked by `make release VERSION=X.Y.Z [NOTES_FILE=path]`.
# Steps:
#   0. Validate VERSION matches semver and that git working tree is clean
#   1. Bump $Script:CABootstrapVersion in ca-bootstrap.ps1
#   2. Run `make smoke` (skipped with SKIP_SMOKE=1)
#   3. Run Pester (skipped with SKIP_TESTS=1)
#   4. Commit "release: vX.Y.Z" with the version bump
#   5. Push main, tag vX.Y.Z, push the tag
#   6. Create the GitHub release using $NOTES_FILE or auto-generated
#      notes from `git log v<previous>..HEAD`.
#
# Refuses to release if:
#   - VERSION isn't semver
#   - Working tree is dirty (use `git stash` or commit first)
#   - The tag already exists locally or on origin
#   - Smoke or tests fail (override with SKIP_SMOKE=1 / SKIP_TESTS=1)
#   - You're not on main (override with FORCE_BRANCH=1)

set -euo pipefail

VERSION="${VERSION:-}"
NOTES_FILE="${NOTES_FILE:-}"
SKIP_SMOKE="${SKIP_SMOKE:-}"
SKIP_TESTS="${SKIP_TESTS:-}"
FORCE_BRANCH="${FORCE_BRANCH:-}"
DRY_RUN="${DRY_RUN:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; X='\033[0m'
err()  { printf "${R}ERROR:${X} %s\n"  "$*" >&2; exit 1; }
ok()   { printf "${G}✓${X} %s\n"       "$*"; }
info() { printf "${B}→${X} %s\n"       "$*"; }
warn() { printf "${Y}⚠${X} %s\n"       "$*"; }

# ---------------------------------------------------------------------------
# 0. Validation
# ---------------------------------------------------------------------------

[ -n "$VERSION" ] || err 'VERSION is required, e.g. make release VERSION=1.2.1'

# Strip leading v if present, then re-add it for the tag.
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] \
    || err "VERSION '$VERSION' is not semver (expected X.Y.Z or X.Y.Z-suffix)"
TAG="v$VERSION"

if [ -z "$FORCE_BRANCH" ]; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [ "$BRANCH" = "main" ] || err "Not on main (currently on '$BRANCH'). Pass FORCE_BRANCH=1 to override."
fi

if ! git diff --quiet HEAD || ! git diff --cached --quiet; then
    err "Working tree is dirty. Commit or stash first."
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    err "Tag $TAG already exists locally."
fi
if git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q .; then
    err "Tag $TAG already exists on origin."
fi

if ! command -v gh >/dev/null 2>&1; then
    err 'gh CLI not installed. Install from https://cli.github.com/.'
fi

ok "VERSION=$VERSION TAG=$TAG (semver, clean tree, tag is new)"

# ---------------------------------------------------------------------------
# 1. Bump version constant
# ---------------------------------------------------------------------------

ORCHESTRATOR="$REPO_ROOT/ca-bootstrap.ps1"
CURRENT=$(grep -oE "Script:CABootstrapVersion = '[^']+'" "$ORCHESTRATOR" | head -1 | sed -E "s/.*= '([^']+)'.*/\1/")
[ -n "$CURRENT" ] || err "Could not parse current version from $ORCHESTRATOR"
info "current version: $CURRENT → new version: $VERSION"

if [ "$CURRENT" = "$VERSION" ]; then
    warn "ca-bootstrap.ps1 already at $VERSION; skipping bump"
else
    if [ -z "$DRY_RUN" ]; then
        # macOS sed and GNU sed both support `-i ''` and `-i.bak`; we use a
        # portable form via perl.
        perl -i -pe "s/(Script:CABootstrapVersion = ')[^']+(')/\${1}$VERSION\${2}/" "$ORCHESTRATOR"
        ok "bumped \$Script:CABootstrapVersion → $VERSION"
    else
        info "DRY_RUN: would bump version constant"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Smoke test
# ---------------------------------------------------------------------------

if [ -z "$SKIP_SMOKE" ]; then
    info "running make smoke..."
    if [ -z "$DRY_RUN" ]; then
        make smoke >/dev/null 2>&1 || err "smoke test failed. Pass SKIP_SMOKE=1 to override."
    fi
    ok "smoke test passed"
else
    warn "SKIP_SMOKE=1 set, skipping smoke test"
fi

# ---------------------------------------------------------------------------
# 3. Pester
# ---------------------------------------------------------------------------

if [ -z "$SKIP_TESTS" ]; then
    info "running Pester..."
    if [ -z "$DRY_RUN" ]; then
        pwsh -NoLogo -Command "
            \$cfg = New-PesterConfiguration
            \$cfg.Run.Path = './tests'
            \$cfg.Output.Verbosity = 'Minimal'
            \$cfg.Run.Exit = \$true
            Invoke-Pester -Configuration \$cfg
        " >/dev/null 2>&1 || err "Pester tests failed. Pass SKIP_TESTS=1 to override."
    fi
    ok "Pester tests passed"
else
    warn "SKIP_TESTS=1 set, skipping Pester"
fi

# ---------------------------------------------------------------------------
# 4. Commit
# ---------------------------------------------------------------------------

if [ -z "$DRY_RUN" ]; then
    if git diff --quiet HEAD; then
        info "no version changes to commit (already at $VERSION on disk)"
    else
        git add ca-bootstrap.ps1
        git commit -m "release: $TAG

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>" >/dev/null
        ok "committed: release: $TAG"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Push + tag + push tag
# ---------------------------------------------------------------------------

if [ -z "$DRY_RUN" ]; then
    git push origin main >/dev/null 2>&1
    ok "pushed main"
    git tag -a "$TAG" -m "Release $TAG"
    git push origin "$TAG" >/dev/null 2>&1
    ok "tagged $TAG and pushed"
else
    info "DRY_RUN: would push main, tag $TAG, push tag"
fi

# ---------------------------------------------------------------------------
# 6. GitHub release
# ---------------------------------------------------------------------------

# Resolve the previous tag for changelog generation.
PREV_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | grep -v "^$TAG$" | head -1 || true)

# Determine the notes body.
if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    NOTES_BODY=$(cat "$NOTES_FILE")
    info "release notes from $NOTES_FILE"
else
    info "auto-generating release notes from $PREV_TAG..$TAG"
    if [ -n "$PREV_TAG" ]; then
        COMMITS=$(git log --pretty=format:'- %s' "$PREV_TAG..HEAD" 2>/dev/null | grep -v '^- release:' || true)
    else
        COMMITS=$(git log --pretty=format:'- %s' HEAD | grep -v '^- release:' | head -50)
    fi
    NOTES_BODY="ca-bootstrap $TAG

## Changes since $PREV_TAG

$COMMITS

## Bootstrap one-liners (pinned to $TAG)

\`\`\`powershell
# Windows
iwr -useb https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/$TAG/bootstrap.ps1 | iex
\`\`\`

\`\`\`bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/$TAG/bootstrap.sh | bash
\`\`\`"
fi

if [ -z "$DRY_RUN" ]; then
    echo "$NOTES_BODY" | gh release create "$TAG" \
        --title "ca-bootstrap $TAG" \
        --notes-file - \
        --target main >/dev/null
    ok "GitHub release created"
    URL=$(gh release view "$TAG" --json url -q .url)
    printf "${G}✓${X} ${B}$URL${X}\n"
else
    info "DRY_RUN: would create GitHub release with notes:"
    echo "$NOTES_BODY"
fi

ok "Release $TAG complete."
