#!/usr/bin/env bash
# ca-bootstrap one-line entrypoint for macOS / Linux.
#
# Two modes:
#   1. Curl-pipe (documented use): no sibling ca-bootstrap.ps1 next to
#      this script. Ensures pwsh + git, clones the repo to a cache,
#      hands off to ca-bootstrap.ps1 setup.
#   2. From a clone: a sibling ca-bootstrap.ps1 exists. Skip the cache
#      and forward all args directly to it.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.sh | bash
#   ./bootstrap.sh doctor               # from a clone — forwards to ca-bootstrap.ps1

set -euo pipefail

# Mode 2 short-circuit: sibling orchestrator detected → exec directly.
# This block runs even when piped via stdin (no $0 path); in that case
# the next condition fails and we fall through to mode 1.
SELF_PATH="${BASH_SOURCE[0]:-}"
if [ -n "$SELF_PATH" ] && [ -f "$(dirname "$SELF_PATH")/ca-bootstrap.ps1" ]; then
    SIBLING="$(cd "$(dirname "$SELF_PATH")" && pwd)/ca-bootstrap.ps1"
    if ! command -v pwsh >/dev/null 2>&1; then
        echo "pwsh not found. Install PowerShell 7+ and re-run." >&2
        exit 1
    fi
    if [ "$#" -eq 0 ]; then set -- setup; fi
    exec pwsh -NoLogo -File "$SIBLING" "$@"
fi

REPO_URL="${CA_BOOTSTRAP_REPO:-https://github.com/ChannelAssist/ca-bootstrap.git}"
REPO_REF="${CA_BOOTSTRAP_REF:-main}"
CACHE_DIR="${CA_BOOTSTRAP_CACHE:-$HOME/.ca-bootstrap/cache}"

color_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
color_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
color_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }

# Read a yes/no answer from the user. Defaults to "Y" for the curl-pipe
# entrypoint (`curl ... | bash` has no usable stdin: it's already at EOF
# because the script body itself was just consumed from it). Reading from
# /dev/tty is the standard escape hatch — it's the controlling terminal
# even when stdin is a pipe. If /dev/tty isn't available either (CI,
# headless), we fall through to the documented default of "Y".
prompt_yn() {
    local prompt="$1" default="${2:-Y}"
    local ans
    if [ -t 0 ]; then
        read -r -p "$prompt " ans
    elif [ -e /dev/tty ]; then
        read -r -p "$prompt " ans </dev/tty
    else
        # Non-interactive (curl-pipe, CI). Honor the default silently.
        ans="$default"
    fi
    [ -z "$ans" ] && ans="$default"
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

detect_os() {
    case "$(uname -s)" in
        Darwin) echo "macos" ;;
        Linux)
            if [[ -f /etc/os-release ]]; then
                . /etc/os-release
                case "${ID:-}${ID_LIKE:-}" in
                    *debian*|*ubuntu*) echo "linux-debian" ;;
                    *rhel*|*fedora*|*centos*) echo "linux-rhel" ;;
                    *) echo "linux-unknown" ;;
                esac
            else
                echo "linux-unknown"
            fi
            ;;
        *) echo "unknown" ;;
    esac
}

install_pwsh() {
    local os
    os=$(detect_os)
    color_blue "Installing PowerShell 7 ($os)..."
    case "$os" in
        macos)
            if command -v brew >/dev/null 2>&1; then
                brew install --cask powershell
            else
                color_red "Homebrew not found. Install from https://brew.sh and re-run."
                exit 2
            fi
            ;;
        linux-debian)
            sudo apt-get update
            sudo apt-get install -y wget apt-transport-https software-properties-common
            local codename; codename=$(. /etc/os-release; echo "${VERSION_CODENAME:-jammy}")
            wget -q "https://packages.microsoft.com/config/ubuntu/$(. /etc/os-release; echo "${VERSION_ID}")/packages-microsoft-prod.deb" -O /tmp/pmp.deb || true
            sudo dpkg -i /tmp/pmp.deb || true
            sudo apt-get update
            sudo apt-get install -y powershell
            ;;
        linux-rhel)
            sudo dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
            sudo dnf install -y powershell
            ;;
        *)
            color_red "Unsupported OS: $os. Install PowerShell 7+ manually:"
            color_red "  https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
            exit 2
            ;;
    esac
    color_green "✓ PowerShell installed."
}

install_git() {
    local os
    os=$(detect_os)
    color_blue "Installing git ($os)..."
    case "$os" in
        macos)        brew install git ;;
        linux-debian) sudo apt-get install -y git ;;
        linux-rhel)   sudo dnf install -y git ;;
        *)            color_red "Install git manually and re-run."; exit 2 ;;
    esac
    color_green "✓ git installed."
}

main() {
    color_blue "ca-bootstrap — preparing your environment"
    echo

    if ! command -v pwsh >/dev/null 2>&1; then
        color_yellow "PowerShell 7+ is not installed. ca-bootstrap requires it."
        if prompt_yn "Install now? [Y/n]" Y; then
            install_pwsh
        else
            color_red "Cannot continue without PowerShell. Exiting."
            exit 1
        fi
    fi

    if ! command -v git >/dev/null 2>&1; then
        color_yellow "git is not installed. ca-bootstrap requires it."
        if prompt_yn "Install now? [Y/n]" Y; then
            install_git
        else
            color_red "Cannot continue without git. Exiting."
            exit 1
        fi
    fi

    mkdir -p "$CACHE_DIR"
    if [[ -d "$CACHE_DIR/.git" ]]; then
        color_blue "Updating ca-bootstrap (cache: $CACHE_DIR)..."
        if ! git -C "$CACHE_DIR" fetch --quiet origin "$REPO_REF" 2>/dev/null; then
            color_yellow "Cache update failed. Refreshing cache from scratch..."
            rm -rf "$CACHE_DIR"
            git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$CACHE_DIR" || {
                color_red "Re-clone also failed. Check ~/.gitconfig for a malformed line and retry."
                exit 1
            }
        else
            git -C "$CACHE_DIR" checkout --quiet "$REPO_REF"
            git -C "$CACHE_DIR" pull --quiet --ff-only origin "$REPO_REF"
        fi
    else
        color_blue "Fetching ca-bootstrap from $REPO_URL ($REPO_REF)..."
        git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$CACHE_DIR"
    fi
    color_green "✓ ca-bootstrap ready."
    echo

    # When invoked via `curl -fsSL ... | bash`, our stdin is the curl pipe
    # — it's already at EOF (the script body itself was just consumed).
    # Without re-attaching, pwsh inherits that empty stdin and Read-Host
    # returns $null on every prompt. The wizard would silently auto-Y
    # through every consent screen, then hard-crash on the first multi-
    # option prompt (Read-CABChoice's `(Read-Host).Trim()` on $null).
    # Re-attach to /dev/tty when stdin is non-tty AND a tty is reachable;
    # otherwise refuse with a helpful message.
    if [ -t 0 ]; then
        exec pwsh -NoLogo -File "$CACHE_DIR/ca-bootstrap.ps1" setup "$@"
    elif [ -e /dev/tty ]; then
        exec pwsh -NoLogo -File "$CACHE_DIR/ca-bootstrap.ps1" setup "$@" </dev/tty
    else
        color_red 'ca-bootstrap setup needs an interactive terminal.'
        echo ''
        echo 'Options:'
        echo '  • Run from a real terminal: download the script first, then bash it'
        echo "      curl -fsSL $REPO_URL/raw/$REPO_REF/bootstrap.sh -o /tmp/cab.sh && bash /tmp/cab.sh"
        echo ''
        echo '  • Or clone the repo and use unattended mode:'
        echo "      git clone $REPO_URL"
        echo '      cd ca-bootstrap'
        echo '      pwsh ./ca-bootstrap.ps1 setup -Unattended -ConfigFile manifest/answers.example.yaml'
        exit 1
    fi
}

main "$@"
