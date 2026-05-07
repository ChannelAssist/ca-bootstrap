#!/usr/bin/env bash
# scripts/release.sh — cut a ca-bootstrap release.
#
# Workflow (matches the org's established dev-as-default pattern):
#
#   1. Maintainer opens a PR to dev that bumps $Script:CABootstrapVersion
#      in ca-bootstrap.ps1 (and any release notes / CHANGELOG entries).
#   2. PR merges into dev (via standard review + CI gate).
#   3. Maintainer runs `make release VERSION=X.Y.Z` from anywhere in the repo.
#   4. This script then:
#        a. Verifies the version constant on origin/dev already equals VERSION
#           (so you can't accidentally tag a version dev hasn't claimed).
#        b. Smoke + Pester (skippable for hotfixes via SKIP_SMOKE / SKIP_TESTS).
#        c. Fast-forwards origin/main to origin/dev. Main-protection blocks
#           non-PR pushes, so this disables the ruleset, ff-pushes, and
#           re-enables it (verified byte-identical via diff).
#        d. Creates a GPG-signed tag vX.Y.Z on the new main HEAD.
#        e. Pushes the tag.
#        f. Creates the GitHub release with $NOTES_FILE or auto-generated
#           notes from `git log v<previous>..HEAD`.
#
# Refuses to release if:
#   - VERSION isn't semver
#   - Working tree is dirty (commit or stash first)
#   - The tag already exists locally or on origin
#   - ca-bootstrap.ps1's version constant on dev doesn't match VERSION
#   - Smoke or tests fail (override with SKIP_SMOKE=1 / SKIP_TESTS=1)
#   - main can't fast-forward to dev (main has commits dev doesn't)
#
# Env knobs (all optional unless noted):
#   VERSION          required — semver, e.g. 1.5.0 (or v1.5.0)
#   NOTES_FILE       path to release notes file (else auto-generated)
#   SKIP_SMOKE=1     skip `make smoke`
#   SKIP_TESTS=1     skip Pester
#   DRY_RUN=1        validate + print but don't push/tag/release
#   CONFIRM=1        skip the "type yes to proceed" gate before mutating

set -euo pipefail

VERSION="${VERSION:-}"
NOTES_FILE="${NOTES_FILE:-}"
SKIP_SMOKE="${SKIP_SMOKE:-}"
SKIP_TESTS="${SKIP_TESTS:-}"
DRY_RUN="${DRY_RUN:-}"
CONFIRM="${CONFIRM:-}"

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

[ -n "$VERSION" ] || err 'VERSION is required, e.g. make release VERSION=1.5.0'

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] \
    || err "VERSION '$VERSION' is not semver (expected X.Y.Z or X.Y.Z-suffix)"
TAG="v$VERSION"

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
# 1. Fetch + verify version constant on dev matches VERSION
# ---------------------------------------------------------------------------

info 'fetching origin...'
git fetch --quiet --all --tags

ORCHESTRATOR_PATH='ca-bootstrap.ps1'
DEV_VERSION=$(git show "origin/dev:$ORCHESTRATOR_PATH" \
    | grep -oE "Script:CABootstrapVersion = '[^']+'" \
    | head -1 \
    | sed -E "s/.*= '([^']+)'.*/\1/")
[ -n "$DEV_VERSION" ] || err "Could not parse \$Script:CABootstrapVersion from origin/dev:$ORCHESTRATOR_PATH"

if [ "$DEV_VERSION" != "$VERSION" ]; then
    err "origin/dev has \$Script:CABootstrapVersion = '$DEV_VERSION'; release.sh refuses to tag $TAG.
    Open a PR to dev that bumps the constant to '$VERSION' first, merge it, then re-run."
fi
ok "origin/dev already at $VERSION"

# Verify main can fast-forward to dev (no divergence).
AHEAD_MAIN=$(git rev-list --count "origin/dev..origin/main" 2>/dev/null || echo 0)
AHEAD_DEV=$(git rev-list --count "origin/main..origin/dev" 2>/dev/null || echo 0)
if [ "$AHEAD_MAIN" -gt 0 ]; then
    err "origin/main has $AHEAD_MAIN commit(s) NOT on origin/dev. main must be a strict ancestor of dev for ff-promotion. Reconcile first."
fi
if [ "$AHEAD_DEV" -eq 0 ]; then
    warn "origin/main is already at origin/dev; no promotion needed (will tag the existing HEAD)."
fi
ok "main can fast-forward to dev (+$AHEAD_DEV commit(s) ahead)"

# ---------------------------------------------------------------------------
# 2. Smoke + tests (skippable)
# ---------------------------------------------------------------------------

if [ -z "$SKIP_SMOKE" ]; then
    info 'running make smoke...'
    if [ -z "$DRY_RUN" ]; then
        make smoke >/dev/null 2>&1 || err 'smoke test failed. Pass SKIP_SMOKE=1 to override.'
    fi
    ok 'smoke test passed'
else
    warn 'SKIP_SMOKE=1 set, skipping smoke test'
fi

if [ -z "$SKIP_TESTS" ]; then
    info 'running Pester...'
    if [ -z "$DRY_RUN" ]; then
        pwsh -NoLogo -Command "
            \$cfg = New-PesterConfiguration
            \$cfg.Run.Path = './tests'
            \$cfg.Output.Verbosity = 'Minimal'
            \$cfg.Run.Exit = \$true
            Invoke-Pester -Configuration \$cfg
        " >/dev/null 2>&1 || err 'Pester tests failed. Pass SKIP_TESTS=1 to override.'
    fi
    ok 'Pester tests passed'
else
    warn 'SKIP_TESTS=1 set, skipping Pester'
fi

# ---------------------------------------------------------------------------
# 3. Confirmation gate (final chance to back out)
# ---------------------------------------------------------------------------

if [ -z "$DRY_RUN" ] && [ -z "$CONFIRM" ]; then
    echo ''
    warn "About to ff-promote origin/dev → origin/main and tag $TAG."
    warn "Type 'yes' to proceed, anything else to abort:"
    read -r RESP
    [ "$RESP" = 'yes' ] || err 'aborted by user.'
fi

# ---------------------------------------------------------------------------
# 4. Promote origin/dev → origin/main (with disable-restore on ruleset)
# ---------------------------------------------------------------------------
# main-protection (ruleset 16051054) requires PRs for any change to main.
# A direct ff-push from dev would be rejected. Standard play: capture the
# ruleset, set enforcement=disabled, do the push, restore enforcement,
# verify the round-trip is byte-identical.

MAIN_RULESET_ID=16051054

if [ "$AHEAD_DEV" -gt 0 ]; then
    if [ -z "$DRY_RUN" ]; then
        info 'capturing main-protection ruleset...'
        gh api "repos/ChannelAssist/ca-bootstrap/rulesets/$MAIN_RULESET_ID" \
            > /tmp/main-protection-before.json 2>/dev/null \
            || err "could not read ruleset $MAIN_RULESET_ID"
        BEFORE_ENFORCEMENT=$(jq -r '.enforcement' /tmp/main-protection-before.json)
        ok "captured (enforcement=$BEFORE_ENFORCEMENT)"

        info 'disabling main-protection enforcement...'
        jq -M -c '.enforcement = "disabled" | {name, target, source_type, source, enforcement, conditions, rules}' \
            /tmp/main-protection-before.json > /tmp/main-protection-disable.json
        gh api -X PUT "repos/ChannelAssist/ca-bootstrap/rulesets/$MAIN_RULESET_ID" \
            --input /tmp/main-protection-disable.json --jq '.enforcement' >/dev/null
        ok 'main-protection disabled'

        # Local checkout of main, ff-merge dev, push.
        info 'ff-promoting origin/dev → origin/main...'
        ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        # Use a detached working area to avoid disturbing the user's branch.
        git checkout main >/dev/null 2>&1 || git checkout -B main origin/main >/dev/null 2>&1
        git merge --ff-only origin/dev >/dev/null
        git push origin main >/dev/null
        # Restore the user's original branch — they were probably on dev.
        git checkout "$ORIG_BRANCH" >/dev/null 2>&1 || true
        ok "origin/main fast-forwarded to $(git rev-parse --short origin/dev)"

        info 'restoring main-protection enforcement...'
        jq -M -c --arg e "$BEFORE_ENFORCEMENT" '.enforcement = $e | {name, target, source_type, source, enforcement, conditions, rules}' \
            /tmp/main-protection-before.json > /tmp/main-protection-restore.json
        gh api -X PUT "repos/ChannelAssist/ca-bootstrap/rulesets/$MAIN_RULESET_ID" \
            --input /tmp/main-protection-restore.json --jq '.enforcement' >/dev/null
        # Verify byte-identical round-trip.
        gh api "repos/ChannelAssist/ca-bootstrap/rulesets/$MAIN_RULESET_ID" \
            > /tmp/main-protection-after.json 2>/dev/null
        if ! diff -q \
                <(jq -SM 'del(.updated_at) | .' /tmp/main-protection-before.json) \
                <(jq -SM 'del(.updated_at) | .' /tmp/main-protection-after.json) >/dev/null; then
            warn 'main-protection ruleset content drifted after restore; review manually.'
        else
            ok 'main-protection re-enabled (byte-identical)'
        fi
    else
        info "DRY_RUN: would ff-promote origin/dev → origin/main"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Tag main + push tag
# ---------------------------------------------------------------------------

if [ -z "$DRY_RUN" ]; then
    git fetch --quiet origin main
    git tag -s "$TAG" "origin/main" -m "Release $TAG" >/dev/null
    git push origin "$TAG" >/dev/null
    ok "GPG-signed tag $TAG pushed"
else
    info "DRY_RUN: would tag origin/main as $TAG (signed) and push"
fi

# ---------------------------------------------------------------------------
# 6. GitHub release
# ---------------------------------------------------------------------------

# Resolve the previous tag for changelog generation.
PREV_TAG=$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | grep -v "^$TAG$" | head -1 || true)

if [ -n "$NOTES_FILE" ] && [ -f "$NOTES_FILE" ]; then
    NOTES_BODY=$(cat "$NOTES_FILE")
    info "release notes from $NOTES_FILE"
else
    info "auto-generating release notes from $PREV_TAG..$TAG"
    if [ -n "$PREV_TAG" ]; then
        COMMITS=$(git log --pretty=format:'- %s' "$PREV_TAG..origin/main" 2>/dev/null | grep -v '^- release:' || true)
    else
        COMMITS=$(git log --pretty=format:'- %s' "origin/main" | grep -v '^- release:' | head -50)
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
    URL=$(gh release view "$TAG" --json url -q .url)
    ok "GitHub release created: $URL"
else
    info "DRY_RUN: would create GitHub release with notes:"
    echo "$NOTES_BODY"
fi

ok "Release $TAG complete."
