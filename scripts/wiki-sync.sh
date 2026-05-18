#!/usr/bin/env bash
#
# ca-bootstrap wiki sync.
#
# NOTE: The push function in this script DELIBERATELY DIVERGES from the
# canonical ChannelAssist wiki-sync push pattern (defined in Keystone
# ADR 012). This repo uses a retry-with-rebase reconcile loop optimised
# for concurrent-write conflict resolution — appropriate because the
# wiki here receives concurrent writes from multiple onboarding flows
# (human contributors running the bootstrap CLI; CI from spawned repos).
# The canonical pattern is optimised for fresh-init / detached-HEAD
# recovery, which is the dominant failure mode for the other 13 repos
# but not for ca-bootstrap.
#
# Both patterns are valid. The divergence is intentional, registered in
# the ADR's Exceptions Register, and approved as of 2026-05-18.
#
# Reference:
#   https://github.com/ChannelAssist/Keystone/blob/dev/content/docs/adr/012-wiki-sync-push-pattern.md
#
# scripts/wiki-sync.sh — mirror ca-bootstrap docs/ tree into the GitHub Wiki.
#
# Usage:
#   ./scripts/wiki-sync.sh clone    # clone the wiki repo (one-time)
#   ./scripts/wiki-sync.sh sync     # copy + transform docs into ./wiki
#   ./scripts/wiki-sync.sh push     # commit + push (with retry-on-divergence)
#
# Pattern follows Keystone and cm-platform-infra: gh-cli auth, wiki dir lives
# inside the repo root, sync rewrites markdown links so wiki rendering works.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIKI_DIR="${REPO_ROOT}/wiki"
WIKI_URL_HTTPS="https://github.com/ChannelAssist/ca-bootstrap.wiki.git"
SOURCE_README="${REPO_ROOT}/README.md"
SOURCE_DESIGN="${REPO_ROOT}/DESIGN.md"
SOURCE_DOCS="${REPO_ROOT}/docs"

color_blue()   { printf '\033[0;34m[INFO] %s\033[0m\n'  "$*"; }
color_green()  { printf '\033[0;32m[OK]   %s\033[0m\n'  "$*"; }
color_yellow() { printf '\033[0;33m[WARN] %s\033[0m\n'  "$*"; }
color_red()    { printf '\033[0;31m[ERR]  %s\033[0m\n'  "$*"; }

cmd_clone() {
    if [[ -d "$WIKI_DIR/.git" ]]; then
        color_yellow "Wiki already cloned at $WIKI_DIR. Pulling latest..."
        git -C "$WIKI_DIR" pull --ff-only
        return 0
    fi
    color_blue "Cloning $WIKI_URL_HTTPS to $WIKI_DIR..."
    if ! git clone "$WIKI_URL_HTTPS" "$WIKI_DIR" 2>/dev/null; then
        color_yellow "Wiki clone failed — the wiki may not be initialized yet."
        color_yellow "Visit https://github.com/ChannelAssist/ca-bootstrap/wiki and create the first page,"
        color_yellow "then re-run 'make wiki-clone'."
        exit 1
    fi
    color_green "Wiki cloned to $WIKI_DIR"
}

# transform_links — rewrite relative markdown links so wiki rendering works.
# Wiki pages live at the wiki root with no directory structure, so we:
#   - rewrite ../DESIGN.md → DESIGN.md
#   - rewrite docs/foo.md → foo.md
#   - rewrite ./foo.md → foo.md
# Any links pointing into the source repo (e.g. .github/workflows/*) become
# absolute github.com URLs.
transform_links() {
    local file="$1"
    # Wiki pages live flat at the wiki root, so:
    #   ../DESIGN.md     → DESIGN.md
    #   ../README.md     → README.md (rendered as Home)
    #   docs/foo.md      → foo.md
    perl -i -pe '
        s|\]\((?:\.\.?/)?docs/([^)]+\.md)\)|](\1)|g;
        s|\]\((?:\.\./)?DESIGN\.md\)|](DESIGN.md)|g;
        s|\]\((?:\.\./)?README\.md\)|](Home.md)|g;
    ' "$file"
}

cmd_sync() {
    if [[ ! -d "$WIKI_DIR/.git" ]]; then
        color_red "Wiki not cloned. Run 'make wiki-clone' first."
        exit 1
    fi

    color_blue "Pulling latest wiki state..."
    git -C "$WIKI_DIR" fetch --quiet origin
    git -C "$WIKI_DIR" reset --quiet --hard origin/master 2>/dev/null \
        || git -C "$WIKI_DIR" reset --quiet --hard origin/main

    color_blue "Cleaning destination..."
    find "$WIKI_DIR" -type f -name '*.md' ! -name '_Sidebar.md' ! -name '_Footer.md' -delete
    find "$WIKI_DIR" -type d -mindepth 1 ! -path "*/.git*" -exec rm -rf {} + 2>/dev/null || true

    color_blue "Copying README → Home.md..."
    cp "$SOURCE_README" "$WIKI_DIR/Home.md"

    color_blue "Copying DESIGN.md..."
    cp "$SOURCE_DESIGN" "$WIKI_DIR/DESIGN.md"

    color_blue "Copying docs/*.md flat into wiki root..."
    if [[ -d "$SOURCE_DOCS" ]]; then
        find "$SOURCE_DOCS" -type f -name '*.md' | while read -r src; do
            cp "$src" "$WIKI_DIR/$(basename "$src")"
        done
    fi

    color_blue "Rewriting links for wiki rendering..."
    find "$WIKI_DIR" -maxdepth 1 -type f -name '*.md' | while read -r f; do
        transform_links "$f"
    done

    color_blue "Generating sidebar..."
    {
        echo "# ca-bootstrap"
        echo ''
        echo '- [[Home]]'
        echo '- [[DESIGN]]'
        echo ''
        echo '## Reference'
        for f in "$WIKI_DIR"/*.md; do
            base=$(basename "$f" .md)
            case "$base" in
                Home|DESIGN|_Sidebar|_Footer) continue ;;
            esac
            echo "- [[$base]]"
        done
    } > "$WIKI_DIR/_Sidebar.md"

    color_blue "Stamping footer..."
    {
        printf '\n---\n*Last synced from `main` at %s UTC. Edit source under `docs/` and run `make wiki-update`.*\n' \
            "$(date -u +'%Y-%m-%d %H:%M')"
    } > "$WIKI_DIR/_Footer.md"

    color_green "Wiki working tree synced."
}

# Push with reconcile-on-divergence (same pattern as Keystone wiki-sync.sh).
cmd_push() {
    if [[ ! -d "$WIKI_DIR/.git" ]]; then
        color_red "Wiki not cloned. Run 'make wiki-clone' first."
        exit 1
    fi
    cd "$WIKI_DIR"

    if [[ -z "$(git status --porcelain)" ]]; then
        color_yellow "No wiki changes to push."
        return 0
    fi

    git add .
    git commit -m "Update wiki documentation from repository" --quiet

    local attempts=0
    local max_attempts=3
    local backoff=2
    while (( attempts < max_attempts )); do
        if git push --quiet 2>/dev/null; then
            color_green "Wiki changes pushed."
            return 0
        fi
        attempts=$((attempts + 1))
        color_yellow "Push failed (attempt $attempts/$max_attempts). Reconciling with remote..."
        git fetch --quiet origin
        local remote_branch
        remote_branch=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo 'origin/master')
        # Prefer local on conflict — wiki content is generated from main repo.
        git merge --quiet -X ours "$remote_branch" --no-edit || true
        sleep "$backoff"
        backoff=$((backoff * 2))
    done

    color_red "Wiki push failed after $max_attempts attempts."
    exit 1
}

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        clone) cmd_clone ;;
        sync)  cmd_sync ;;
        push)  cmd_push ;;
        help|--help|-h)
            echo "Usage: $0 {clone|sync|push}"
            ;;
        *)
            color_red "Unknown command: $cmd"
            echo "Usage: $0 {clone|sync|push}"
            exit 1
            ;;
    esac
}

main "$@"
