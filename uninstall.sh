#!/bin/bash
# Claude Monitor — Uninstaller
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "\033[0;36m${BOLD}=>${NC} $1"; }
ok()    { echo -e "${GREEN}${BOLD}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}${BOLD}!${NC} $1"; }

echo ""
echo -e "${BOLD}Claude Monitor — Uninstall${NC}"
echo ""

# ── Stop the app ──────────────────────────────────────────
pkill -f "ClaudeMonitor.app" 2>/dev/null && ok "Stopped Claude Monitor" || true

# ── Remove LaunchAgent ────────────────────────────────────
PLIST="$HOME/Library/LaunchAgents/com.claude.monitor.plist"
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "Removed launch agent"
fi

# ── Remove app bundle ────────────────────────────────────
APP="$CLAUDE_DIR/ClaudeMonitor.app"
if [ -d "$APP" ]; then
  rm -rf "$APP"
  ok "Removed ClaudeMonitor.app"
fi

# ── Remove hooks ─────────────────────────────────────────
HOOKS=(
  insights.sh session-start.sh stop.sh notify.sh post-commit.sh
  agent-start.sh agent-stop.sh track-reads.sh read-before-edit.sh
  pre-compact.sh learn-from-failure.sh
)

removed=0
for hook in "${HOOKS[@]}"; do
  if [ -f "$HOOKS_DIR/$hook" ]; then
    rm -f "$HOOKS_DIR/$hook"
    ((removed++))
  fi
done
ok "Removed $removed hooks"

# ── Remove statusline ────────────────────────────────────
if [ -f "$CLAUDE_DIR/statusline.sh" ]; then
  rm -f "$CLAUDE_DIR/statusline.sh"
  ok "Removed statusline.sh"
fi

# ── Clean up temp files ──────────────────────────────────
info "Cleaning up temporary files..."
rm -f "$CLAUDE_DIR"/.ctx_* "$CLAUDE_DIR"/.state_* "$CLAUDE_DIR"/.ctxlog_* \
      "$CLAUDE_DIR"/.tty_map_* "$CLAUDE_DIR"/.tty_resolved_* "$CLAUDE_DIR"/.activity_* \
      "$CLAUDE_DIR"/.files_read "$CLAUDE_DIR"/.active_agents "$CLAUDE_DIR"/.agent_activity \
      "$CLAUDE_DIR"/.session_names "$CLAUDE_DIR"/.sessions.json \
      "$CLAUDE_DIR"/.usage_cache.json "$CLAUDE_DIR"/.weekly_start_pct \
      "$CLAUDE_DIR"/.build_failures.log "$CLAUDE_DIR"/.ctx_pct_* \
      2>/dev/null
ok "Cleaned up temporary files"

echo ""
warn "Note: settings.json was NOT modified."
warn "Remove the 'hooks' and 'statusLine' sections manually if desired."
warn "Backup is at: $CLAUDE_DIR/settings.json.pre-monitor-backup"
echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
