#!/usr/bin/env bash
# scripts/release-full.sh — bump-and-release in one command.
#
# Wraps scripts/release.sh by adding the version-bump PR cycle:
#
#   1. Branch chore/v$VERSION-release off origin/dev
#   2. Bump $Script:CABootstrapVersion in ca-bootstrap.ps1
#   3. Commit + push, open PR to dev
#   4. Admin-merge the bump PR via dev-protection disable-restore
#      (an EXIT trap restores enforcement even if the merge fails)
#   5. Hand off to scripts/release.sh which does manifest-edit, smoke,
#      Pester, ff-promote dev→main, GPG-signed tag, GH release
#
# Trade-off vs. the manual `make release` flow: this skips review on
# the bump PR. Use for hotfix releases or single-maintainer projects.
# For multi-maintainer projects where bumps need review (CHANGELOG
# entry, breaking-change tags, etc.), use the 3-step manual flow:
#   1. Open PR to dev that bumps $Script:CABootstrapVersion
#   2. Merge it after review
#   3. Run `make release VERSION=X.Y.Z`
#
# If origin/dev is already at $VERSION, this script skips the bump PR
# step and proceeds directly to release.sh — so re-running after a
# manual bump is safe.
#
# Env knobs (all optional unless noted):
#   VERSION              required — semver
#   NOTES_FILE           passthrough to release.sh
#   SKIP_SMOKE=1         passthrough to release.sh
#   SKIP_TESTS=1         passthrough to release.sh
#   SKIP_MANIFEST_EDIT=1 passthrough to release.sh
#   DRY_RUN=1            validate + print but don't push/merge/tag/release
#   CONFIRM=1            skip the upfront confirmation gate

set -euo pipefail

VERSION="${VERSION:-}"
NOTES_FILE="${NOTES_FILE:-}"
SKIP_SMOKE="${SKIP_SMOKE:-}"
SKIP_TESTS="${SKIP_TESTS:-}"
SKIP_MANIFEST_EDIT="${SKIP_MANIFEST_EDIT:-}"
DRY_RUN="${DRY_RUN:-}"
CONFIRM="${CONFIRM:-}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; X='\033[0m'
err()  { printf "${R}ERROR:${X} %s\n"  "$*" >&2; exit 1; }
ok()   { printf "${G}✓${X} %s\n"       "$*"; }
info() { printf "${B}→${X} %s\n"       "$*"; }
warn() { printf "${Y}⚠${X} %s\n"       "$*"; }

# State for trap (initialised before any failable step that disables a ruleset).
RULESET_DISABLED=0
BEFORE_ENFORCEMENT=''
DEV_RULESET_ID=''
REPO_SLUG=''
TMPDIR_FULL="$(mktemp -d -t cab-relfull.XXXXXX)"

cleanup_on_exit() {
    local rc=$?
    # Best-effort restore using the ORIGINAL enforcement value, not a
    # hardcoded "active". GitHub rulesets support enforcement=active|
    # disabled|evaluate; if the maintainer was running their dev-
    # protection in evaluate mode (audit-only), forcing it back to
    # active would silently change policy.
    if [ "$RULESET_DISABLED" = '1' ] \
        && [ -n "$DEV_RULESET_ID" ] \
        && [ -n "$REPO_SLUG" ] \
        && [ -n "$BEFORE_ENFORCEMENT" ] \
        && [ -f "$TMPDIR_FULL/dev-protection-before.json" ]; then
        warn "exit $rc while dev-protection disabled — restoring to '$BEFORE_ENFORCEMENT'..."
        if jq -M -c --arg e "$BEFORE_ENFORCEMENT" \
                '.enforcement = $e | {name, target, source_type, source, enforcement, conditions, rules}' \
                "$TMPDIR_FULL/dev-protection-before.json" \
                > "$TMPDIR_FULL/dev-protection-restore.json" 2>/dev/null \
            && gh api -X PUT "repos/$REPO_SLUG/rulesets/$DEV_RULESET_ID" \
                --input "$TMPDIR_FULL/dev-protection-restore.json" --jq '.enforcement' >/dev/null 2>&1; then
            warn "dev-protection re-enabled (best-effort after exit $rc)"
        else
            printf "${R}*** CRITICAL: dev-protection ruleset $DEV_RULESET_ID may still be DISABLED. Re-enable manually:\n" >&2
            printf "    gh api -X PUT repos/$REPO_SLUG/rulesets/$DEV_RULESET_ID --input '%s/dev-protection-before.json'${X}\n" "$TMPDIR_FULL" >&2
            # Preserve the snapshot in TMPDIR_FULL for forensics —
            # don't delete on this critical-failure path so the
            # sysop can use the printed gh api command.
            return $rc
        fi
    fi
    # Always clean up the tempdir except in the critical-failure
    # branch above (which returned early). Previously we only cleaned
    # on rc=0, leaving JSON snapshots behind on every failed run.
    if [ -d "$TMPDIR_FULL" ]; then
        rm -rf "$TMPDIR_FULL"
    fi
    return $rc
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# 0. Validation
# ---------------------------------------------------------------------------

[ -n "$VERSION" ] || err 'VERSION is required, e.g. make release-full VERSION=1.5.0'

VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] \
    || err "VERSION '$VERSION' is not semver (expected X.Y.Z or X.Y.Z-suffix)"
TAG="v$VERSION"

if ! git diff --quiet HEAD || ! git diff --cached --quiet; then
    err 'Working tree is dirty. Commit or stash first.'
fi

if git rev-parse "$TAG" >/dev/null 2>&1; then
    err "Tag $TAG already exists locally."
fi
if git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q .; then
    err "Tag $TAG already exists on origin."
fi

for dep in gh jq diff perl; do
    command -v "$dep" >/dev/null 2>&1 \
        || err "$dep not on PATH (required for the bump-and-merge play)."
done

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
REPO_SLUG=$(printf '%s' "$ORIGIN_URL" \
    | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||' \
    | tr -d '[:space:]')
if [ -z "$REPO_SLUG" ] || ! [[ "$REPO_SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    REPO_SLUG=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
fi
[ -n "$REPO_SLUG" ] || err 'Could not derive repo slug from origin remote.'

ok "VERSION=$VERSION TAG=$TAG REPO=$REPO_SLUG"

# ---------------------------------------------------------------------------
# 1. Inspect origin/dev's current version
# ---------------------------------------------------------------------------

info 'fetching origin...'
git fetch --quiet --all --tags

DEV_VERSION=$(git show "origin/dev:ca-bootstrap.ps1" \
    | grep -oE "Script:CABootstrapVersion = '[^']+'" \
    | head -1 \
    | sed -E "s/.*= '([^']+)'.*/\1/")
[ -n "$DEV_VERSION" ] || err 'Could not parse $Script:CABootstrapVersion from origin/dev:ca-bootstrap.ps1'

if [ "$DEV_VERSION" = "$VERSION" ]; then
    info "origin/dev is already at $VERSION — skipping bump PR; proceeding directly to release.sh"
    SKIP_BUMP_PR=1
else
    info "origin/dev currently at $DEV_VERSION; will bump to $VERSION via auto-merged PR"
    SKIP_BUMP_PR=
fi

# ---------------------------------------------------------------------------
# 2. Confirmation gate
# ---------------------------------------------------------------------------

if [ -z "$DRY_RUN" ] && [ -z "$CONFIRM" ]; then
    echo ''
    warn "About to: bump dev to $VERSION (auto-merged PR), then run release.sh to ff-promote main, tag $TAG, create release."
    warn "Type 'yes' to proceed, anything else to abort:"
    read -r RESP
    [ "$RESP" = 'yes' ] || err 'aborted by user.'
fi

# ---------------------------------------------------------------------------
# 3. Bump-PR cycle (skipped if dev is already at target)
# ---------------------------------------------------------------------------

if [ -z "$SKIP_BUMP_PR" ]; then
    BUMP_BRANCH="chore/v$VERSION-release"

    if [ -z "$DRY_RUN" ]; then
        # Refuse if the branch already exists on origin — defends against
        # a previous run that crashed mid-flight; the maintainer should
        # clean up before retrying.
        if git ls-remote --heads origin "$BUMP_BRANCH" 2>/dev/null | grep -q .; then
            err "Branch $BUMP_BRANCH already exists on origin. Investigate (\`gh pr list --head $BUMP_BRANCH\`); delete manually if stale, then re-run."
        fi

        ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        info "creating bump branch $BUMP_BRANCH off origin/dev..."
        git checkout -B "$BUMP_BRANCH" origin/dev >/dev/null 2>&1

        info "bumping ca-bootstrap.ps1 → $VERSION..."
        perl -i -pe "s/(Script:CABootstrapVersion = ')[^']+(')/\${1}$VERSION\${2}/" ca-bootstrap.ps1

        if git diff --quiet HEAD; then
            err "Bump produced no diff — \$Script:CABootstrapVersion may have been at $VERSION already on dev (the earlier check should have caught this)."
        fi

        git add ca-bootstrap.ps1
        # No Co-Authored-By footer here — this commit fires from any
        # maintainer's machine running `make release-full`, not from
        # a Claude session, so attributing it to Claude would be
        # incorrect. The commit author/email come from the maintainer's
        # local git config, which is the right answer.
        git commit -m "release: bump version to $TAG

Auto-generated by make release-full VERSION=$VERSION." >/dev/null
        ok 'committed bump'

        info "pushing $BUMP_BRANCH..."
        git push -u origin "$BUMP_BRANCH" >/dev/null 2>&1
        ok 'pushed'

        info 'opening bump PR...'
        PR_URL=$(gh pr create --base dev --head "$BUMP_BRANCH" \
            --title "release: bump version to $TAG" \
            --body "Auto-generated by \`make release-full VERSION=$VERSION\`. Bumps \$Script:CABootstrapVersion to $VERSION on the road to tagging $TAG. Auto-merged immediately by the script via dev-protection disable-restore play; no human review on the bump itself." \
            --label chore 2>&1 | tail -1)
        PR_NUM=$(printf '%s' "$PR_URL" | grep -oE '[0-9]+$')
        [ -n "$PR_NUM" ] || err "Could not extract PR number from URL: $PR_URL"
        ok "PR #$PR_NUM created"

        # Locate dev-protection ruleset by name (fork-safe).
        info 'locating dev-protection ruleset...'
        DEV_RULESET_ID=$(gh api "repos/$REPO_SLUG/rulesets" --jq '.[] | select(.name == "dev-protection") | .id' 2>/dev/null | head -1 || true)
        [ -n "$DEV_RULESET_ID" ] || err "Could not find dev-protection ruleset on $REPO_SLUG."
        ok "dev-protection ruleset id = $DEV_RULESET_ID"

        info 'capturing dev-protection state...'
        gh api "repos/$REPO_SLUG/rulesets/$DEV_RULESET_ID" \
            > "$TMPDIR_FULL/dev-protection-before.json" 2>/dev/null \
            || err "could not read ruleset $DEV_RULESET_ID"
        BEFORE_ENFORCEMENT=$(jq -r '.enforcement' "$TMPDIR_FULL/dev-protection-before.json")
        ok "captured (enforcement=$BEFORE_ENFORCEMENT)"

        info 'disabling dev-protection enforcement...'
        jq -M -c '.enforcement = "disabled" | {name, target, source_type, source, enforcement, conditions, rules}' \
            "$TMPDIR_FULL/dev-protection-before.json" > "$TMPDIR_FULL/dev-protection-disable.json"
        gh api -X PUT "repos/$REPO_SLUG/rulesets/$DEV_RULESET_ID" \
            --input "$TMPDIR_FULL/dev-protection-disable.json" --jq '.enforcement' >/dev/null
        RULESET_DISABLED=1
        ok 'dev-protection disabled'

        info "squash-merging bump PR #$PR_NUM..."
        gh pr merge "$PR_NUM" --squash \
            --subject "release: bump version to $TAG (#$PR_NUM)" \
            --body "Auto-merged by make release-full VERSION=$VERSION." >/dev/null
        ok 'merged'

        info 'restoring dev-protection enforcement...'
        jq -M -c --arg e "$BEFORE_ENFORCEMENT" '.enforcement = $e | {name, target, source_type, source, enforcement, conditions, rules}' \
            "$TMPDIR_FULL/dev-protection-before.json" > "$TMPDIR_FULL/dev-protection-restore.json"
        gh api -X PUT "repos/$REPO_SLUG/rulesets/$DEV_RULESET_ID" \
            --input "$TMPDIR_FULL/dev-protection-restore.json" --jq '.enforcement' >/dev/null
        RULESET_DISABLED=0

        gh api "repos/$REPO_SLUG/rulesets/$DEV_RULESET_ID" \
            > "$TMPDIR_FULL/dev-protection-after.json" 2>/dev/null
        if ! diff -q \
                <(jq -SM 'del(.updated_at) | .' "$TMPDIR_FULL/dev-protection-before.json") \
                <(jq -SM 'del(.updated_at) | .' "$TMPDIR_FULL/dev-protection-after.json") >/dev/null; then
            warn 'dev-protection ruleset content drifted after restore; review manually.'
        else
            ok 'dev-protection re-enabled (byte-identical)'
        fi

        # Restore the user's original branch + clean up the local bump branch.
        git checkout "$ORIG_BRANCH" >/dev/null 2>&1 || git checkout main >/dev/null 2>&1
        git branch -D "$BUMP_BRANCH" 2>/dev/null || true

        info 'fetching to sync with new dev HEAD...'
        git fetch --quiet origin
    else
        info "DRY_RUN: would create $BUMP_BRANCH off origin/dev, bump version, push, open PR, admin-merge"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Hand off to release.sh (it does the rest: manifest-edit → smoke +
#    Pester → ff-promote dev→main → tag → GH release)
# ---------------------------------------------------------------------------

echo ''
info '======================================================================'
info '  Bump complete. Continuing to scripts/release.sh:'
info '    manifest-edit → smoke + Pester → ff-promote dev→main → tag → GH release'
info '======================================================================'
echo ''

# DRY_RUN handling has two cases:
#
#   * Bump-PR was skipped (SKIP_BUMP_PR=1, dev's version already at
#     target): the precondition release.sh checks (origin/dev's
#     version == VERSION) is genuinely satisfied, so we CAN cascade
#     DRY_RUN through. This validates the full chain end-to-end.
#
#   * Bump-PR was needed (SKIP_BUMP_PR empty): we didn't actually
#     bump in dry-run, so release.sh would refuse with a misleading
#     "version mismatch" error. Short-circuit instead and explain.
if [ -n "$DRY_RUN" ] && [ -z "$SKIP_BUMP_PR" ]; then
    info "DRY_RUN: scripts/release.sh would run next with VERSION=$VERSION."
    info '         Skipping the actual handoff because dev was not bumped'
    info "         in this dry-run (it'd refuse to tag $TAG against the"
    info '         unchanged version constant). To dry-run the release.sh'
    info "         half in isolation, bump dev manually first then run"
    info '         `make release-dry-run VERSION='"$VERSION"'`.'
    ok "DRY_RUN: release-full plan validated through bump step (no mutations)."
    exit 0
fi

# Run release.sh as a child process so the EXIT trap in this script still
# fires for tempdir cleanup. CONFIRM=1 skips the second confirmation gate
# (we already confirmed up top).
VERSION="$VERSION" \
    NOTES_FILE="$NOTES_FILE" \
    SKIP_SMOKE="$SKIP_SMOKE" \
    SKIP_TESTS="$SKIP_TESTS" \
    SKIP_MANIFEST_EDIT="$SKIP_MANIFEST_EDIT" \
    DRY_RUN="$DRY_RUN" \
    CONFIRM=1 \
    "$REPO_ROOT/scripts/release.sh"
