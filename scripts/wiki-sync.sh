#!/usr/bin/env bash
#
# ca-bootstrap wiki sync.
#
# The push function follows the canonical ChannelAssist wiki-sync push
# pattern defined in Keystone ADR 013 (which supersedes ADR 012 — see
# the ADR for the history). The canonical handles concurrent-write
# divergence (the failure mode that originally motivated this repo's
# divergence under ADR 012) AND detached-HEAD recovery AND first-time
# push.
#
# Reference:
#   https://github.com/ChannelAssist/Keystone/blob/dev/content/docs/adr/013-wiki-sync-canonical-revised.md
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
        color_yellow "then re-run 'make wiki-update'."
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
        color_red "Wiki not cloned. Run 'make wiki-update' first."
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
        # Footer text must match the PowerShell peer (scripts/wiki-sync.ps1)
        # byte-for-byte — see that file's matching comment.
        printf '\n---\n*Last synced from `main` at %s UTC. Edit source under `docs/` and run `make wiki-update` (or `./make.ps1 wiki-update` on Windows).*\n' \
            "$(date -u +'%Y-%m-%d %H:%M')"
    } > "$WIKI_DIR/_Footer.md"

    color_green "Wiki working tree synced."
}

# cmd_full — single "do it all" entrypoint. Clones the wiki if absent,
# then delegates to cmd_sync (which owns the fetch/reset) and cmd_push.
# The redundant fetch/reset that used to live here was removed: cmd_sync
# already does a fetch+reset at its start, so doing it twice created two
# separate reset-points — the second (in cmd_sync) always wins, but the
# gap between them is a silent failure surface if the first reset succeeds
# and the second fails after further state mutation. One place owns the pull.
cmd_full() {
    if [[ ! -d "$WIKI_DIR/.git" ]]; then
        cmd_clone
    fi
    cmd_sync
    cmd_push
}

# Push with reconcile-on-divergence (same pattern as Keystone wiki-sync.sh).
cmd_push() {
    if [[ ! -d "$WIKI_DIR/.git" ]]; then
        color_red "Wiki not cloned. Run 'make wiki-update' first."
        exit 1
    fi
    cd "$WIKI_DIR"

    if [[ -z "$(git status --porcelain)" ]]; then
        color_yellow "No wiki changes to push."
        return 0
    fi

    git add .
    git commit -m "Update wiki documentation from repository" --quiet

    # Push pattern per ADR 013 (Keystone). Detached-HEAD-safe, retries on divergence.
    if [ -z "$(git branch --show-current)" ]; then
        local default_branch
        default_branch="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || echo master)"
        color_yellow "HEAD is detached; checking out $default_branch at current commit"
        git checkout -B "$default_branch"
    fi
    if git push origin HEAD 2>/dev/null; then
        color_green "Wiki changes pushed."
        return 0
    elif git push -u origin HEAD 2>/dev/null; then
        color_green "Wiki changes pushed (set upstream)."
        return 0
    else
        color_yellow "Push rejected (likely concurrent-write divergence); fetching and rebasing..."
        git fetch --quiet origin || true
        if git pull --rebase --quiet origin HEAD 2>/dev/null && git push origin HEAD; then
            color_green "Wiki changes pushed (after rebase)."
            return 0
        else
            color_red "Wiki push failed — manual intervention required (see Keystone ADR 013)."
            exit 1
        fi
    fi
}

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        clone) cmd_clone ;;
        sync)  cmd_sync  ;;
        push)  cmd_push  ;;
        full)  cmd_full  ;;
        help|--help|-h)
            echo "Usage: $0 {clone|sync|push|full}"
            ;;
        *)
            color_red "Unknown command: $cmd"
            echo "Usage: $0 {clone|sync|push|full}"
            exit 1
            ;;
    esac
}

main "$@"
