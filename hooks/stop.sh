#!/bin/bash
# Stop hook — mark session as waiting + update tracking
# Hook type: Stop
set -uo pipefail

INPUT=$(cat)
DIR=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")

# ── Session tracking ──────────────────────────────────────
SESSIONS_FILE="$HOME/.claude/.sessions.json"
if [ -n "$SESSION_ID" ] && [ -f "$SESSIONS_FILE" ]; then
  NOW=$(date +%s)
  jq --arg id "$SESSION_ID" --argjson now "$NOW" \
    '[ .[] | if .id == $id then .lastActive = $now else . end ]' \
    "$SESSIONS_FILE" > "${SESSIONS_FILE}.tmp" 2>/dev/null && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
fi

# ── Mark session as WAITING (Claude finished, needs input) ──
if [ -n "$SESSION_ID" ]; then
  echo "waiting" > "$HOME/.claude/.state_$SESSION_ID" 2>/dev/null

  # Capture context window percentage
  CTX_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // empty' 2>/dev/null || echo "")
  [ -n "$CTX_PCT" ] && echo "$CTX_PCT" > "$HOME/.claude/.ctx_pct_$SESSION_ID" 2>/dev/null
fi

# ── Auto-handoff: save dirty state to handoff.md ─────────
[ -z "$DIR" ] && exit 0

if cd "$DIR" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

  if [ "$DIRTY" -gt 0 ]; then
    CHANGED=$(git status --porcelain 2>/dev/null | head -10 | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')

    mkdir -p "$DIR/.claude"
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

    if ! grep -q "Auto-saved $TIMESTAMP" "$DIR/.claude/handoff.md" 2>/dev/null; then
      echo "" >> "$DIR/.claude/handoff.md"
      echo "## Auto-saved $TIMESTAMP" >> "$DIR/.claude/handoff.md"
      echo "- Branch: $BRANCH" >> "$DIR/.claude/handoff.md"
      echo "- $DIRTY uncommitted changes: $CHANGED" >> "$DIR/.claude/handoff.md"
    fi

    jq -n --arg m "Auto-saved session state to handoff.md ($DIRTY uncommitted changes on $BRANCH)" \
      '{"systemMessage": $m}'
  fi
fi
