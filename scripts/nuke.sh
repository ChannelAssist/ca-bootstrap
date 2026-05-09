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
#   INCLUDE_TOOLS=1   also pass -IncludeTools to the inner undo so
#                     manifest tools get uninstalled too. Destructive
#                     across the whole machine; default off.
#   CONFIRM=1         skip the interactive confirmation prompt. Required
#                     for unattended/scripted use.
#   DRY_RUN=1         print the plan and the underlying commands but do
#                     not execute them. Useful for validating the chain.
#   CA_BOOTSTRAP_STATE  passthrough — the rm -rf step removes whichever
#                     directory this points at (defaults to ~/.ca-bootstrap).
#                     The path is validated before the rm: it must be
#                     non-empty, absolute, not equal to / or $HOME, and
#                     end in '.ca-bootstrap'. Anything else is refused.
#
# Exit codes:
#   0   success (or DRY_RUN completed)
#   1   user declined confirmation, OR refused unsafe STATE_DIR
#   7   propagated from the inner `undo` invocation when a destructive
#       op fails mid-flight (commands/undo.ps1 returns 7 in that case).
#       The state-dir removal step is skipped so the next nuke can
#       retry. `undo` itself only ever emits 0 / 1 / 7 today; if a new
#       exit code is added there, propagate it here too.

set -euo pipefail

INCLUDE_TOOLS="${INCLUDE_TOOLS:-}"
CONFIRM="${CONFIRM:-}"
DRY_RUN="${DRY_RUN:-}"
# IMPORTANT: use ${VAR-default} (no colon) so the default only kicks in
# when CA_BOOTSTRAP_STATE is genuinely UNSET. With ${VAR:-default} (the
# more common form), an explicitly-empty CA_BOOTSTRAP_STATE='' falls
# back to the default — which during PR #42 nuke-test development
# turned a hermetic test case into a real ~/.ca-bootstrap rm. The
# distinction matters: tests that want to assert "empty is refused"
# need to actually reach STATE_DIR='' so the safety guard below can
# fire.
STATE_DIR="${CA_BOOTSTRAP_STATE-$HOME/.ca-bootstrap}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; X='\033[0m'
err()  { printf "${R}ERROR:${X} %s\n"  "$*" >&2; exit 1; }
ok()   { printf "${G}✓${X} %s\n"       "$*"; }
info() { printf "${B}→${X} %s\n"       "$*"; }
warn() { printf "${Y}⚠${X} %s\n"       "$*"; }

PWSH="${PWSH:-pwsh}"
command -v "$PWSH" >/dev/null 2>&1 || err "$PWSH not found on PATH"

# If the user is on Windows and inherited CA_BOOTSTRAP_STATE from a
# PowerShell session (Windows-form path: `C:\Users\foo\.ca-bootstrap`),
# the safety guards below would refuse it for failing the absolute-path
# check (`/*` doesn't match a drive-letter prefix). Translate via
# cygpath when it's available — Git Bash and MSYS ship it; native
# WSL invocations don't need it because PowerShell-on-WSL emits
# POSIX paths already. If cygpath isn't on PATH, we let the safety
# guards fire so the user gets a clear error rather than a silent
# wrong-path nuke.
case "$STATE_DIR" in
    [A-Za-z]:\\*|[A-Za-z]:/*)
        if command -v cygpath >/dev/null 2>&1; then
            translated=$(cygpath -u -- "$STATE_DIR" 2>/dev/null || true)
            if [ -n "$translated" ]; then
                info "Translating Windows-form CA_BOOTSTRAP_STATE='$STATE_DIR' to POSIX '$translated' via cygpath."
                STATE_DIR="$translated"
            fi
        fi
        ;;
esac

# Validate STATE_DIR before we go anywhere near a confirmation prompt.
# A misconfigured CA_BOOTSTRAP_STATE (set to / or $HOME by accident, or
# left as an empty string) would otherwise turn a confirmed YES into an
# rm -rf disaster. The contract is narrow: ca-bootstrap state dirs end
# in '.ca-bootstrap'; any other path is treated as user error and
# refused with a clear message. Tests work within this contract by
# placing a '.ca-bootstrap' subdirectory inside their tempdir.
case "$STATE_DIR" in
    "")    err "CA_BOOTSTRAP_STATE is empty — refuse to nuke." ;;
    "/")   err "CA_BOOTSTRAP_STATE='/' — refuse to nuke the root filesystem." ;;
    "$HOME"|"$HOME/")
        err "CA_BOOTSTRAP_STATE='$STATE_DIR' equals \$HOME — refuse to nuke the home directory."
        ;;
esac
case "$STATE_DIR" in
    /*) ;; # absolute path is required
    *)  err "CA_BOOTSTRAP_STATE='$STATE_DIR' is not absolute — refuse to nuke." ;;
esac
case "$STATE_DIR" in
    */.ca-bootstrap|*/.ca-bootstrap/) ;; # fine — recognized state-dir name
    *)  err "CA_BOOTSTRAP_STATE='$STATE_DIR' does not end in '.ca-bootstrap' — refuse to nuke. Rename your state dir or unset the variable." ;;
esac
# Depth check: refuse paths with fewer than 3 components from /. So
# `/Users/peter/.ca-bootstrap` (3 components) passes, `/.ca-bootstrap`
# (1 component) is refused. This catches the case where $HOME is
# somehow empty and the default resolves to literally `/.ca-bootstrap`
# — without it the rm would target the root filesystem.
n_components=$(printf '%s\n' "$STATE_DIR" | tr '/' '\n' | grep -cv '^$' || true)
if [ "${n_components:-0}" -lt 3 ]; then
    err "CA_BOOTSTRAP_STATE='$STATE_DIR' has too few path components (need ≥3, got $n_components) — refuse to nuke."
fi

# Build the undo argument list. PowerShell binds parameters by leading
# dash + name; hyphenated double-dash forms (--include-tools, etc.) do
# NOT bind because the hyphen inside the name confuses the parser, so
# we use the PascalCase / single-dash form everywhere. We also do NOT
# pass -Unattended: that flag requires -ConfigFile + -Force together,
# and we don't want to ship a fake answer file just to suppress the
# inner prompts. -Force is the bypass we actually need; the user has
# already typed YES to nuke, so any per-category prompt undo emits
# inside its own loop is acceptable UX.
UNDO_ARGS=(undo -All -IncludeFolders -Force)
if [ "$INCLUDE_TOOLS" = "1" ]; then
    UNDO_ARGS+=(-IncludeTools)
fi

# Render the plan up front so the user sees exactly what's about to happen
# before any keystroke. Mirrors the release.sh / release-full.sh shape.
printf "%sca-bootstrap nuke%s — full-purge plan:\n" "$B" "$X"
printf "  • %s\n" "Reverse every journaled action via ca-bootstrap.ps1 ${UNDO_ARGS[*]}"
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
    info "DRY_RUN: would run: $PWSH -NoLogo -File ./ca-bootstrap.ps1 ${UNDO_ARGS[*]}"
    info "DRY_RUN: would run: rm -rf $STATE_DIR"
    ok "DRY_RUN: nuke plan validated (no mutations)."
    exit 0
fi

# Run undo. "Nothing to undo" is exit 0 (see commands/undo.ps1 line 28),
# so a non-zero return is a real failure: user quit (1), mid-operation
# breakage (7), or a safety refusal (8). Propagate the code and stop —
# leaving the state dir intact lets the user retry without losing
# whatever partial reversal happened. Pre-fix, we silently swallowed
# the code and removed the state dir anyway, which masked a flag-binding
# bug for an entire review cycle.
info "Reversing journaled actions..."
set +e
"$PWSH" -NoLogo -File ./ca-bootstrap.ps1 "${UNDO_ARGS[@]}"
undo_rc=$?
set -e
if [ "$undo_rc" -ne 0 ]; then
    warn "undo exited $undo_rc — leaving state dir in place so you can retry."
    exit "$undo_rc"
fi
ok "undo completed."

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
