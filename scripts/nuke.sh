#!/usr/bin/env bash
# scripts/nuke.sh — full-purge wrapper for ca-bootstrap.
#
# Reverses every journaled action (workspace folders, repos, git identity,
# plugin link), then removes the entire ca-bootstrap state directory
# (~/.ca-bootstrap/ by default; honors $CA_BOOTSTRAP_STATE for tests).
#
# Tools (.NET 10, Node 20, Python 3.12, Docker, VS Code, Claude Code,
# Copilot CLI, etc.) are NOT uninstalled by default — those are typically
# shared with other projects on the machine, so removing them is opt-in
# via INCLUDE_TOOLS=1.
#
# Env knobs:
#   INCLUDE_TOOLS=1   also pass --include-tools to the inner undo so
#                     manifest tools get uninstalled too. Destructive
#                     across the whole machine; default off.
#   CONFIRM=1         skip the interactive confirmation prompt. Required
#                     for unattended/scripted use.
#   DRY_RUN=1         print the plan and the underlying commands but do
#                     not execute them. Useful for validating the chain.
#   CA_BOOTSTRAP_STATE  passthrough — the rm -rf step removes whichever
#                     directory this points at (defaults to ~/.ca-bootstrap).
#
# Exit codes:
#   0   success (or DRY_RUN completed)
#   1   user declined confirmation, or undo failed

set -euo pipefail

INCLUDE_TOOLS="${INCLUDE_TOOLS:-}"
CONFIRM="${CONFIRM:-}"
DRY_RUN="${DRY_RUN:-}"
STATE_DIR="${CA_BOOTSTRAP_STATE:-$HOME/.ca-bootstrap}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; X='\033[0m'
err()  { printf "${R}ERROR:${X} %s\n"  "$*" >&2; exit 1; }
ok()   { printf "${G}✓${X} %s\n"       "$*"; }
info() { printf "${B}→${X} %s\n"       "$*"; }
warn() { printf "${Y}⚠${X} %s\n"       "$*"; }

PWSH="${PWSH:-pwsh}"
command -v "$PWSH" >/dev/null 2>&1 || err "$PWSH not found on PATH"

# Build the undo argument list. Always pass --all --include-folders --force
# (the whole point of `nuke`); --include-tools is gated.
UNDO_ARGS=(--all --include-folders --force --unattended)
if [ "$INCLUDE_TOOLS" = "1" ]; then
    UNDO_ARGS+=(--include-tools)
fi

# Render the plan up front so the user sees exactly what's about to happen
# before any keystroke. Mirrors the release.sh / release-full.sh shape.
printf "%sca-bootstrap nuke%s — full-purge plan:\n" "$B" "$X"
printf "  • %s\n" "Reverse every journaled action via ca-bootstrap.ps1 undo ${UNDO_ARGS[*]}"
printf "      (workspace folders, cloned repos, git includeIf, plugin link)\n"
if [ "$INCLUDE_TOOLS" = "1" ]; then
    printf "  • %s\n" "Uninstall manifest tools (.NET 10, Node 20, Python 3.12, Docker, VS Code, Claude Code, Copilot CLI, ...)"
    printf "      %sWARNING:%s this affects every project on this machine, not just ChannelAssist.\n" "$Y" "$X"
fi
printf "  • %s\n" "Remove the ca-bootstrap state directory: $STATE_DIR"
printf "      (journal, runs/, last-run.log, cache, lock dir)\n"
echo

if [ "$CONFIRM" = "1" ]; then
    info "CONFIRM=1 — skipping interactive prompt."
elif [ "$DRY_RUN" = "1" ]; then
    info "DRY_RUN=1 — skipping interactive prompt (no mutations would happen anyway)."
else
    # Prefer /dev/tty so a piped stdin (`echo y | make nuke`) can't
    # accidentally confirm. Fall back to stdin only when /dev/tty isn't
    # actually open for read+write (some CI sandboxes inherit a
    # /dev/tty entry that isn't connected — opening it then errors with
    # "Device not configured", which under `set -e` would crash the
    # script before the read even ran).
    prompt='Type YES (uppercase) to proceed, anything else to abort: '
    reply=''
    tty_usable=0
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        # Probe the tty by trying to write the prompt and read one line
        # inside a brace group whose stderr is fully redirected. The
        # group-level redirect catches "Device not configured" / ENXIO
        # noise that some CI sandboxes emit when /dev/tty exists but
        # isn't connected — without it, the shell prints the failure
        # before our 2>/dev/null on the inner redirects can fire.
        if { printf "%s" "$prompt" > /dev/tty \
            && IFS= read -r reply < /dev/tty; } 2>/dev/null; then
            tty_usable=1
        fi
    fi
    if [ "$tty_usable" -ne 1 ]; then
        printf "%s" "$prompt"
        IFS= read -r reply || reply=''
    fi
    if [ "$reply" != "YES" ]; then
        warn "Aborted (received: '$reply')."
        exit 1
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    info "DRY_RUN: would run: $PWSH -NoLogo -File ./ca-bootstrap.ps1 undo ${UNDO_ARGS[*]}"
    info "DRY_RUN: would run: rm -rf $STATE_DIR"
    ok "DRY_RUN: nuke plan validated (no mutations)."
    exit 0
fi

# Run undo. We deliberately don't `set -e`-fail on undo's exit code: a
# user with no journaled actions yet (fresh checkout, never ran setup)
# will hit "nothing to undo" which is fine for our purposes — the
# state-dir removal step still runs.
info "Reversing journaled actions..."
if "$PWSH" -NoLogo -File ./ca-bootstrap.ps1 undo "${UNDO_ARGS[@]}"; then
    ok "undo completed."
else
    rc=$?
    warn "undo exited $rc — continuing to state-dir removal anyway."
fi

# Remove the state dir. This step is the actual "leave no trace" piece —
# even if undo missed something (e.g., a manually-created file in
# ~/.ca-bootstrap/runs/), this wipes it.
if [ -d "$STATE_DIR" ]; then
    info "Removing $STATE_DIR..."
    rm -rf "$STATE_DIR"
    ok "$STATE_DIR removed."
else
    info "$STATE_DIR not present — already clean."
fi

ok "ca-bootstrap nuke complete."
echo
printf "Next steps to start fresh:\n"
printf "  • %smake setup%s                     # rerun the wizard\n"  "$B" "$X"
printf "  • %smake doctor%s                    # verify a clean slate\n" "$B" "$X"
