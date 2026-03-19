#!/bin/bash
# Claude Monitor — One-command setup for macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/VargaGergo-Git/Claude-Monitor/main/setup.sh | bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}${BOLD}=>${NC} $1"; }
ok()    { echo -e "${GREEN}${BOLD}✓${NC} $1"; }
err()   { echo -e "${RED}${BOLD}✗${NC} $1"; }

echo ""
echo -e "${BOLD}Claude Monitor${NC} — One-command setup"
echo ""

# Prerequisites
if ! command -v git &>/dev/null; then
    err "git is required. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo -e "${CYAN}${BOLD}=>${NC} jq not found — installing via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install jq
    else
        err "jq is required. Install with: brew install jq"
        exit 1
    fi
fi

# Clone to temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

info "Downloading Claude Monitor..."
git clone --depth 1 --quiet https://github.com/VargaGergo-Git/Claude-Monitor.git "$TMPDIR/claude-monitor"
ok "Downloaded"

# Run installer
cd "$TMPDIR/claude-monitor"
chmod +x install.sh
./install.sh

echo ""
ok "Setup complete — Claude Monitor is ready"
