#!/bin/bash
# Claude Monitor — One-command installer
# Usage: ./install.sh           (full install: app + hooks + statusline)
#        ./install.sh --hooks   (hooks + statusline only, no menu bar app)
#        ./install.sh --app     (menu bar app only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}${BOLD}=>${NC} $1"; }
ok()    { echo -e "${GREEN}${BOLD}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}${BOLD}!${NC} $1"; }
err()   { echo -e "${RED}${BOLD}✗${NC} $1"; }

echo ""
echo -e "${BOLD}Claude Monitor${NC} — Menu bar app + hooks for Claude Code"
echo ""

# ── Parse args ────────────────────────────────────────────
MODE="full"
case "${1:-}" in
  --hooks|--hooks-only) MODE="hooks" ;;
  --app|--app-only)     MODE="app" ;;
  --help|-h)
    echo "Usage: ./install.sh [--hooks|--app]"
    echo ""
    echo "  (no args)  Full install: menu bar app + hooks + statusline"
    echo "  --hooks    Hooks + statusline only (no menu bar app)"
    echo "  --app      Menu bar app only (no hooks)"
    exit 0
    ;;
esac

# ── Prerequisites ─────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  err "jq is required but not installed."
  echo "  Install with: brew install jq"
  exit 1
fi

if ! command -v swiftc &>/dev/null && [ "$MODE" != "hooks" ]; then
  warn "swiftc not found — skipping menu bar app build"
  warn "Install Xcode Command Line Tools: xcode-select --install"
  MODE="hooks"
fi

mkdir -p "$CLAUDE_DIR" "$HOOKS_DIR"

# ── Install hooks ─────────────────────────────────────────
install_hooks() {
  info "Installing hooks to $HOOKS_DIR..."

  local hooks=(
    insights.sh
    session-start.sh
    stop.sh
    notify.sh
    post-commit.sh
    agent-start.sh
    agent-stop.sh
    track-reads.sh
    read-before-edit.sh
    pre-compact.sh
    learn-from-failure.sh
  )

  local installed=0
  local skipped=0

  for hook in "${hooks[@]}"; do
    local src="$SCRIPT_DIR/hooks/$hook"
    local dst="$HOOKS_DIR/$hook"

    if [ ! -f "$src" ]; then
      warn "Source not found: $src"
      continue
    fi

    if [ -f "$dst" ]; then
      # Check if it's the same file
      if diff -q "$src" "$dst" &>/dev/null; then
        ((skipped++))
        continue
      fi
      # Back up existing
      cp "$dst" "${dst}.backup"
      warn "Backed up existing $hook to ${hook}.backup"
    fi

    cp "$src" "$dst"
    chmod +x "$dst"
    ((installed++))
  done

  ok "Hooks: $installed installed, $skipped already up-to-date"
}

# ── Install statusline ───────────────────────────────────
install_statusline() {
  info "Installing statusline..."

  local src="$SCRIPT_DIR/statusline/statusline.sh"
  local dst="$CLAUDE_DIR/statusline.sh"

  if [ -f "$dst" ] && diff -q "$src" "$dst" &>/dev/null; then
    ok "Statusline already up-to-date"
    return
  fi

  if [ -f "$dst" ]; then
    cp "$dst" "${dst}.backup"
    warn "Backed up existing statusline.sh"
  fi

  cp "$src" "$dst"
  chmod +x "$dst"
  ok "Statusline installed"
}

# ── Configure settings.json ──────────────────────────────
configure_settings() {
  info "Configuring settings.json..."

  if [ ! -f "$SETTINGS" ]; then
    # No settings file — create from template (strip comments)
    jq 'del(._comment, ._instructions)' "$SCRIPT_DIR/settings-template.json" > "$SETTINGS"
    ok "Created settings.json with hooks configuration"
    return
  fi

  # Settings file exists — merge hooks carefully
  local BACKUP="${SETTINGS}.pre-monitor-backup"
  cp "$SETTINGS" "$BACKUP"

  # Check if hooks are already configured
  if jq -e '.hooks.PreToolUse' "$SETTINGS" &>/dev/null; then
    warn "Hooks already configured in settings.json — not overwriting"
    warn "Compare with settings-template.json to see what's new"
    echo ""
    echo "  To see differences:"
    echo "    diff <(jq '.hooks' $SETTINGS) <(jq '.hooks' $SCRIPT_DIR/settings-template.json)"
    echo ""
    return
  fi

  # Merge hooks and statusLine into existing settings
  local TEMPLATE="$SCRIPT_DIR/settings-template.json"
  jq -s '.[0] * {hooks: .[1].hooks, statusLine: .[1].statusLine}' "$SETTINGS" "$TEMPLATE" > "${SETTINGS}.tmp"
  mv "${SETTINGS}.tmp" "$SETTINGS"

  ok "Merged hooks into existing settings.json"
  ok "Backup saved to $BACKUP"
}

# ── Build menu bar app ────────────────────────────────────
build_app() {
  info "Building Claude Monitor menu bar app..."

  local APP_DIR="$CLAUDE_DIR/ClaudeMonitor.app"

  # Kill existing instance
  pkill -f "ClaudeMonitor.app" 2>/dev/null || true
  sleep 0.5

  # Detect architecture
  local ARCH=$(uname -m)
  local TARGET
  case "$ARCH" in
    arm64) TARGET="arm64-apple-macosx14.0" ;;
    x86_64) TARGET="x86_64-apple-macosx14.0" ;;
    *) TARGET="arm64-apple-macosx14.0" ;;
  esac

  # Build
  local BUILD_DIR="$SCRIPT_DIR/app"
  swiftc -o "$BUILD_DIR/ClaudeMonitor" "$BUILD_DIR/Sources/main.swift" \
    -framework AppKit \
    -O \
    -target "$TARGET" \
    2>&1

  # Package .app bundle
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR/Contents/MacOS"
  cp "$BUILD_DIR/ClaudeMonitor" "$APP_DIR/Contents/MacOS/"
  cp "$BUILD_DIR/Info.plist" "$APP_DIR/Contents/"

  # Clean up loose binary
  rm -f "$BUILD_DIR/ClaudeMonitor"

  ok "App installed to $APP_DIR"

  # Launch
  open "$APP_DIR"
  ok "Claude Monitor is running in your menu bar"
}

# ── Execute ───────────────────────────────────────────────
case "$MODE" in
  full)
    install_hooks
    install_statusline
    configure_settings
    build_app
    ;;
  hooks)
    install_hooks
    install_statusline
    configure_settings
    ;;
  app)
    build_app
    ;;
esac

echo ""
echo -e "${GREEN}${BOLD}Installation complete!${NC}"
echo ""

if [ "$MODE" != "app" ]; then
  echo "What was installed:"
  echo "  Hooks (11)     ~/.claude/hooks/"
  echo "  Statusline     ~/.claude/statusline.sh"
  echo "  Settings       ~/.claude/settings.json"
  echo ""
fi

if [ "$MODE" != "hooks" ]; then
  echo "  Menu bar app   ~/.claude/ClaudeMonitor.app"
  echo ""
  echo "Launch at login: toggle in the app's Settings menu"
fi

echo ""
echo "Start a new Claude Code session to see everything in action."
