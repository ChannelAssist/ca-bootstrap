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
#        a. Verifies the version constant on origin/dev already equals VERSION.
#        b. Smoke + Pester (skippable for hotfixes via SKIP_SMOKE / SKIP_TESTS).
#        c. Fast-forwards origin/main to origin/dev. main-protection blocks
#           non-PR pushes, so this disables the ruleset, ff-pushes, and
#           re-enables it (verified byte-identical via diff). An EXIT trap
#           guarantees the ruleset is restored even if a later step fails.
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
#   - Required tools missing (gh, jq, diff)
#   - The main-protection ruleset can't be located by name
#
# Env knobs (all optional unless noted):
#   VERSION              required — semver, e.g. 1.5.0 (or v1.5.0)
#   NOTES_FILE           path to release notes file (else auto-generated)
#   SKIP_SMOKE=1         skip `make smoke`
#   SKIP_TESTS=1         skip Pester
#   SKIP_MANIFEST_EDIT=1 skip the interactive manifest-edit step (CI / hands-off)
#   DRY_RUN=1            validate + print but don't push/tag/release
#   CONFIRM=1            skip the "type yes to proceed" gate before mutating

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

# ---------------------------------------------------------------------------
# State carried across the trap (must initialise before any failable step
# can disable the ruleset, so trap can read them safely on early exits).
# ---------------------------------------------------------------------------
RULESET_DISABLED=0
BEFORE_ENFORCEMENT=''
MAIN_RULESET_ID=''
REPO_SLUG=''
TMPDIR_RELEASE="$(mktemp -d -t cab-release.XXXXXX)"

cleanup_on_exit() {
    local rc=$?
    # Best-effort restore: if we disabled the ruleset and didn't get to
    # the restore step (e.g. trap fired due to set -e on an intermediate
    # command), put it back. Without this, a mid-flight error leaves
    # main-protection wide open for the next unwary push.
    if [ "$RULESET_DISABLED" = '1' ] \
        && [ -n "$MAIN_RULESET_ID" ] \
        && [ -n "$REPO_SLUG" ] \
        && [ -n "$BEFORE_ENFORCEMENT" ]; then
        warn "exit code $rc while main-protection was disabled — restoring..."
        if jq -M -c --arg e "$BEFORE_ENFORCEMENT" \
                '.enforcement = $e | {name, target, source_type, source, enforcement, conditions, rules}' \
                "$TMPDIR_RELEASE/main-protection-before.json" \
                > "$TMPDIR_RELEASE/main-protection-restore.json" 2>/dev/null \
            && gh api -X PUT "repos/$REPO_SLUG/rulesets/$MAIN_RULESET_ID" \
                --input "$TMPDIR_RELEASE/main-protection-restore.json" --jq '.enforcement' >/dev/null 2>&1; then
            warn "main-protection enforcement re-enabled (best-effort after exit $rc)"
        else
            printf "${R}*** CRITICAL: main-protection ruleset $MAIN_RULESET_ID may still be DISABLED. Re-enable manually:\n" >&2
            printf "    gh api -X PUT repos/$REPO_SLUG/rulesets/$MAIN_RULESET_ID --input '%s/main-protection-before.json'${X}\n" "$TMPDIR_RELEASE" >&2
            # Preserve the snapshot in TMPDIR_RELEASE for forensics —
            # only delete on clean exit.
            return $rc
        fi
    fi
    if [ -d "$TMPDIR_RELEASE" ]; then
        rm -rf "$TMPDIR_RELEASE"
    fi
    return $rc
}
trap cleanup_on_exit EXIT

# ---------------------------------------------------------------------------
# 0. Validation
# ---------------------------------------------------------------------------

[ -n "$VERSION" ] || err 'VERSION is required, e.g. make release VERSION=1.5.0'

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

# Hard dependencies — fail fast before mutating anything (and before
# the ruleset disable, so we don't enter the danger zone half-armed).
for dep in gh jq diff; do
    command -v "$dep" >/dev/null 2>&1 \
        || err "$dep not on PATH (required for the ruleset disable-restore play)."
done

# Resolve the GitHub repo from `origin` so a fork running this script
# operates against its own remote, not the upstream — critical for the
# ruleset API calls below. Fall back to `gh repo view` for environments
# where origin is set to an alias.
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || true)
REPO_SLUG=$(printf '%s' "$ORIGIN_URL" \
    | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|\.git$||' \
    | tr -d '[:space:]')
if [ -z "$REPO_SLUG" ] || ! [[ "$REPO_SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    REPO_SLUG=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
fi
[ -n "$REPO_SLUG" ] || err 'Could not derive repo slug from `git remote get-url origin` or `gh repo view`.'
ok "VERSION=$VERSION TAG=$TAG REPO=$REPO_SLUG (semver, clean tree, tag is new)"

# ---------------------------------------------------------------------------
# 0.5. Interactive manifest review (skippable for CI / hands-off releases)
# ---------------------------------------------------------------------------
# Surfaces every repo in the org against manifest/repos.yaml so the
# maintainer can curate add/remove entries before tagging. If anything
# changes the working tree, abort: the changes need to land on dev
# via a PR before the release tag goes on main. Without this gate,
# someone could ship a release that lags the manifest by a maintenance
# cycle.

if [ -n "$SKIP_MANIFEST_EDIT" ]; then
    warn 'SKIP_MANIFEST_EDIT=1 set, skipping interactive manifest review'
elif [ -n "$DRY_RUN" ]; then
    info 'DRY_RUN: manifest-edit would run here (skipping the actual interactive review)'
else
    info 'reviewing manifest against the live org...'
    pwsh -NoLogo -File ./ca-bootstrap.ps1 manifest-edit \
        || err 'manifest-edit failed — see output above.'
    if ! git diff --quiet HEAD -- manifest/repos.yaml; then
        warn ''
        warn 'manifest/repos.yaml was modified by manifest-edit.'
        warn 'Commit + push to dev via a PR, merge it, then re-run `make release VERSION='"$VERSION"'`.'
        warn ''
        warn 'This gate ensures the release commit on main reflects the curated manifest.'
        err 'aborting: manifest changes need a PR cycle before tagging.'
    fi
    ok 'manifest review complete (no changes, safe to continue)'
fi

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

AHEAD_MAIN=$(git rev-list --count "origin/dev..origin/main" 2>/dev/null || echo 0)
AHEAD_DEV=$(git rev-list --count "origin/main..origin/dev" 2>/dev/null || echo 0)
if [ "$AHEAD_MAIN" -gt 0 ]; then
    err "origin/main has $AHEAD_MAIN commit(s) NOT on origin/dev. main must be a strict ancestor of dev for ff-promotion. Reconcile first."
fi
if [ "$AHEAD_DEV" -eq 0 ]; then
    warn 'origin/main is already at origin/dev; no promotion needed (will tag the existing HEAD).'
fi
ok "main can fast-forward to dev (+$AHEAD_DEV commit(s) ahead)"

# ---------------------------------------------------------------------------
# 2. Smoke + tests (skippable; messaging differentiates skipped from passed)
# ---------------------------------------------------------------------------

if [ -n "$SKIP_SMOKE" ]; then
    warn 'SKIP_SMOKE=1 set, skipping smoke test'
elif [ -n "$DRY_RUN" ]; then
    info 'DRY_RUN: smoke test would run here (skipping the actual `make smoke`)'
else
    info 'running make smoke...'
    make smoke >/dev/null 2>&1 || err 'smoke test failed. Pass SKIP_SMOKE=1 to override.'
    ok 'smoke test passed'
fi

if [ -n "$SKIP_TESTS" ]; then
    warn 'SKIP_TESTS=1 set, skipping Pester'
elif [ -n "$DRY_RUN" ]; then
    info 'DRY_RUN: Pester would run here (skipping the actual Invoke-Pester)'
else
    info 'running Pester...'
    pwsh -NoLogo -Command "
        \$cfg = New-PesterConfiguration
        \$cfg.Run.Path = './tests'
        \$cfg.Output.Verbosity = 'Minimal'
        \$cfg.Run.Exit = \$true
        Invoke-Pester -Configuration \$cfg
    " >/dev/null 2>&1 || err 'Pester tests failed. Pass SKIP_TESTS=1 to override.'
    ok 'Pester tests passed'
fi

# ---------------------------------------------------------------------------
# 3. Locate main-protection ruleset by name (fork-safe)
# ---------------------------------------------------------------------------

info 'locating main-protection ruleset...'
MAIN_RULESET_ID=$(gh api "repos/$REPO_SLUG/rulesets" --jq '.[] | select(.name == "main-protection") | .id' 2>/dev/null | head -1 || true)
if [ -z "$MAIN_RULESET_ID" ]; then
    err "Could not find a ruleset named 'main-protection' on $REPO_SLUG. Either it doesn't exist (no protection to disable — push directly?) or the API call failed."
fi
ok "main-protection ruleset id = $MAIN_RULESET_ID"

# ---------------------------------------------------------------------------
# 4. Confirmation gate
# ---------------------------------------------------------------------------

if [ -z "$DRY_RUN" ] && [ -z "$CONFIRM" ]; then
    echo ''
    warn "About to ff-promote origin/dev → origin/main and tag $TAG on $REPO_SLUG."
    warn "Type 'yes' to proceed, anything else to abort:"
    read -r RESP
    [ "$RESP" = 'yes' ] || err 'aborted by user.'
fi

# ---------------------------------------------------------------------------
# 5. Promote origin/dev → origin/main (with disable-restore on ruleset)
# ---------------------------------------------------------------------------

if [ "$AHEAD_DEV" -gt 0 ]; then
    if [ -z "$DRY_RUN" ]; then
        info 'capturing main-protection ruleset...'
        gh api "repos/$REPO_SLUG/rulesets/$MAIN_RULESET_ID" \
            > "$TMPDIR_RELEASE/main-protection-before.json" 2>/dev/null \
            || err "could not read ruleset $MAIN_RULESET_ID on $REPO_SLUG"
        BEFORE_ENFORCEMENT=$(jq -r '.enforcement' "$TMPDIR_RELEASE/main-protection-before.json")
        ok "captured (enforcement=$BEFORE_ENFORCEMENT)"

        info 'disabling main-protection enforcement...'
        jq -M -c '.enforcement = "disabled" | {name, target, source_type, source, enforcement, conditions, rules}' \
            "$TMPDIR_RELEASE/main-protection-before.json" > "$TMPDIR_RELEASE/main-protection-disable.json"
        gh api -X PUT "repos/$REPO_SLUG/rulesets/$MAIN_RULESET_ID" \
            --input "$TMPDIR_RELEASE/main-protection-disable.json" --jq '.enforcement' >/dev/null
        # Critical: from now until the matching restore, any error path
        # must trigger the EXIT trap to put the ruleset back.
        RULESET_DISABLED=1
        ok 'main-protection disabled'

        info 'ff-promoting origin/dev → origin/main...'
        ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        git checkout main >/dev/null 2>&1 || git checkout -B main origin/main >/dev/null 2>&1
        git merge --ff-only origin/dev >/dev/null
        git push origin main >/dev/null
        git checkout "$ORIG_BRANCH" >/dev/null 2>&1 || true
        ok "origin/main fast-forwarded to $(git rev-parse --short origin/dev)"

        info 'restoring main-protection enforcement...'
        jq -M -c --arg e "$BEFORE_ENFORCEMENT" '.enforcement = $e | {name, target, source_type, source, enforcement, conditions, rules}' \
            "$TMPDIR_RELEASE/main-protection-before.json" > "$TMPDIR_RELEASE/main-protection-restore.json"
        gh api -X PUT "repos/$REPO_SLUG/rulesets/$MAIN_RULESET_ID" \
            --input "$TMPDIR_RELEASE/main-protection-restore.json" --jq '.enforcement' >/dev/null
        RULESET_DISABLED=0

        gh api "repos/$REPO_SLUG/rulesets/$MAIN_RULESET_ID" \
            > "$TMPDIR_RELEASE/main-protection-after.json" 2>/dev/null
        if ! diff -q \
                <(jq -SM 'del(.updated_at) | .' "$TMPDIR_RELEASE/main-protection-before.json") \
                <(jq -SM 'del(.updated_at) | .' "$TMPDIR_RELEASE/main-protection-after.json") >/dev/null; then
            warn 'main-protection ruleset content drifted after restore; review manually.'
        else
            ok 'main-protection re-enabled (byte-identical)'
        fi
    else
        info 'DRY_RUN: would ff-promote origin/dev → origin/main with disable-restore on main-protection'
    fi
fi

# ---------------------------------------------------------------------------
# 6. Tag main + push tag
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
# 7. GitHub release
# ---------------------------------------------------------------------------

# Pick the previous tag for changelog generation. Two filters matter:
#
#   1. `--merged origin/main` — exclude tags that point at orphaned
#      commits (e.g. archive tags from work that was later squashed
#      and dropped via PR). Without this, a `--sort=-v:refname` walk
#      can pick a higher-numbered orphan tag and produce a misleading
#      "Changes since vX.Y.Z" header pointing at unreachable history.
#
#   2. `grep -v "^$TAG$"` — drop the tag we're about to create (it
#      was just pushed in step 6 above; without this we'd pick
#      ourselves as our own predecessor and emit empty notes).
#
# `--sort=-v:refname` picks the highest semver among the survivors.
PREV_TAG=$(git tag --merged origin/main --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' \
    | grep -v "^$TAG$" \
    | head -1 || true)

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
iwr -useb https://raw.githubusercontent.com/$REPO_SLUG/$TAG/bootstrap.ps1 | iex
\`\`\`

\`\`\`bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/$REPO_SLUG/$TAG/bootstrap.sh | bash
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
    info 'DRY_RUN: would create GitHub release with notes:'
    echo "$NOTES_BODY"
fi

ok "Release $TAG complete."
