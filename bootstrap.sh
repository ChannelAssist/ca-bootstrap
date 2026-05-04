#!/usr/bin/env bash
# ca-bootstrap one-line entrypoint for macOS / Linux.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ChannelAssist/ca-bootstrap/main/bootstrap.sh | bash
#
# This script does the minimum to hand off to ca-bootstrap.ps1:
#   1. Ensure PowerShell 7+ is available (install if missing)
#   2. Ensure git is available (install if missing)
#   3. Clone or update the ca-bootstrap repository to a cache directory
#   4. Hand off to pwsh ca-bootstrap.ps1 setup

set -euo pipefail

REPO_URL="${CA_BOOTSTRAP_REPO:-https://github.com/ChannelAssist/ca-bootstrap.git}"
REPO_REF="${CA_BOOTSTRAP_REF:-main}"
CACHE_DIR="${CA_BOOTSTRAP_CACHE:-$HOME/.ca-bootstrap/cache}"

color_red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
color_green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
color_yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
color_blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }

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
        read -p "Install now? [Y/n] " ans
        case "${ans:-Y}" in [Yy]*|"") install_pwsh ;; *) color_red "Cannot continue without PowerShell. Exiting."; exit 1 ;; esac
    fi

    if ! command -v git >/dev/null 2>&1; then
        color_yellow "git is not installed. ca-bootstrap requires it."
        read -p "Install now? [Y/n] " ans
        case "${ans:-Y}" in [Yy]*|"") install_git ;; *) color_red "Cannot continue without git. Exiting."; exit 1 ;; esac
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

    exec pwsh -NoLogo -File "$CACHE_DIR/ca-bootstrap.ps1" setup "$@"
}

main "$@"
