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
# headless), we fall through to the documented default of "Y" so the
# bootstrap behavior matches the docs/tui.md promise of "first-time
# users get the TUI by default".
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

# Detect a Python 3.10+ on PATH; echo the binary name (or empty).
detect_python() {
    # `python` (no version suffix) covers pyenv, conda, and homebrew
    # configurations where the only usable interpreter on PATH isn't
    # a versioned `python3` symlink. We still version-check the result,
    # so a system `python` that's actually 2.x is correctly rejected.
    for cand in python3 python3.13 python3.12 python3.11 python3.10 python; do
        if command -v "$cand" >/dev/null 2>&1; then
            local ver major minor
            ver=$("$cand" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
            major="${ver%.*}"; minor="${ver#*.}"
            if [ "$major" -ge 3 ] && [ "$minor" -ge 10 ]; then echo "$cand"; return 0; fi
        fi
    done
    echo ""
}

# Install Python 3.10+ via the platform's package manager. Returns 0 on
# success, non-zero if the install couldn't be attempted (no package
# manager, user declined, etc.). Caller treats failure as a soft fallback
# to the CLI.
install_python() {
    local os
    os=$(detect_os)
    color_blue "Installing Python 3.12 ($os)..."
    case "$os" in
        macos)
            if command -v brew >/dev/null 2>&1; then
                brew install python@3.12 || return 1
            else
                color_yellow "  Homebrew not found. Skipping Python install (cab-tui will be unavailable)."
                color_yellow "  Install Homebrew (https://brew.sh) and re-run to enable the TUI."
                return 1
            fi
            ;;
        linux-debian)
            sudo apt-get update -qq || return 1
            sudo apt-get install -y python3 python3-pip python3-venv || return 1
            ;;
        linux-rhel)
            sudo dnf install -y python3 python3-pip || return 1
            ;;
        *)
            color_yellow "  Unsupported OS for automatic Python install. Install Python 3.10+ manually."
            return 1
            ;;
    esac
    color_green "✓ Python installed."
}

# Optional: install Python 3.10+ and the cab-tui front-end. The wizard
# auto-detects this and uses the rich TUI when present; absence is fine
# (silent fallback to the legacy Read-Host CLI). Only attempted when
# CA_BOOTSTRAP_NO_TUI is unset.
install_python_and_tui() {
    if [ -n "${CA_BOOTSTRAP_NO_TUI:-}" ]; then return 0; fi
    if [ ! -d "$1" ]; then return 0; fi   # cache may not be cloned yet
    local cab_tui_dir="$1/cab-tui"
    if [ ! -d "$cab_tui_dir" ]; then return 0; fi   # older release without TUI

    local py
    py=$(detect_python)

    if [ -z "$py" ]; then
        color_yellow "Python 3.10+ not found — installing now to enable the TUI."
        if ! prompt_yn "Install Python automatically? [Y/n]" Y; then
            color_yellow "  Skipping cab-tui install (set CA_BOOTSTRAP_NO_TUI=1 to silence this on re-run)."
            return 0
        fi
        if ! install_python; then
            color_yellow "  Python install failed/declined; continuing with the legacy CLI."
            return 0
        fi
        py=$(detect_python)
        if [ -z "$py" ]; then
            color_yellow "  Python still not detected post-install; continuing with the legacy CLI."
            return 0
        fi
    fi

    # Probe whether cab_tui is already importable (e.g. previous run).
    if "$py" -m cab_tui --check >/dev/null 2>&1; then
        color_green "✓ cab-tui already installed."
        return 0
    fi

    color_blue "Installing cab-tui (optional rich TUI front-end)..."
    # Prefer Poetry per ChannelAssist SDLC; fall back to pip when Poetry
    # isn't on PATH yet (curl-pipe first run on a fresh machine).
    local install_ok=0
    if command -v poetry >/dev/null 2>&1; then
        if (cd "$cab_tui_dir" && poetry install --quiet 2>/dev/null); then
            install_ok=1
        fi
    fi
    if [ "$install_ok" = "0" ]; then
        if ! "$py" -m pip install --quiet --upgrade pip 2>/dev/null; then
            color_yellow "  pip upgrade failed; continuing with whatever pip is available."
        fi
        if "$py" -m pip install --quiet -e "$cab_tui_dir" 2>/dev/null; then
            install_ok=1
        fi
    fi
    if [ "$install_ok" = "1" ]; then
        # macOS Python 3.14 + Hatchling: clear UF_HIDDEN on the editable
        # .pth so site.py picks it up. See docs/tui.md.
        if [ "$(detect_os)" = "macos" ]; then
            local site_pkgs
            site_pkgs=$("$py" -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "")
            if [ -n "$site_pkgs" ]; then
                find "$site_pkgs" -name "_editable_impl_cab_tui.pth" -exec chflags nohidden {} \; 2>/dev/null || true
            fi
        fi
        color_green "✓ cab-tui installed; setup will auto-launch the TUI."
    else
        color_yellow "  cab-tui install failed; continuing with the legacy Read-Host CLI."
        color_yellow "  (Set CA_BOOTSTRAP_NO_TUI=1 to silence this message.)"
    fi
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

    # Optionally install Python + cab-tui so the rich TUI is the default.
    # Best-effort: any failure here is a soft fallback to the CLI.
    install_python_and_tui "$CACHE_DIR"
    echo

    exec pwsh -NoLogo -File "$CACHE_DIR/ca-bootstrap.ps1" setup "$@"
}

main "$@"
