#!/bin/bash
# Track active agents — decrement count, clean oldest activity entry, update session
# Hook type: SubagentStop
set -uo pipefail

COUNTER="$HOME/.claude/.active_agents"
AGENTS_FILE="$HOME/.claude/.agent_activity"
SESSIONS_FILE="$HOME/.claude/.sessions.json"

INPUT=$(cat)

# Decrement count
CURRENT=$(cat "$COUNTER" 2>/dev/null || echo "1")
NEW=$((CURRENT - 1))
[ "$NEW" -lt 0 ] && NEW=0
echo "$NEW" > "$COUNTER"

# Remove oldest activity entry
if [ -f "$AGENTS_FILE" ] && [ "$NEW" -eq 0 ]; then
  > "$AGENTS_FILE"
elif [ -f "$AGENTS_FILE" ]; then
  tail -n "$NEW" "$AGENTS_FILE" > "${AGENTS_FILE}.tmp" 2>/dev/null && mv "${AGENTS_FILE}.tmp" "$AGENTS_FILE"
fi

# Update session agent count
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
if [ -n "$SESSION_ID" ] && [ -f "$SESSIONS_FILE" ]; then
  jq --arg id "$SESSION_ID" --argjson count "$NEW" \
    '[ .[] | if .id == $id then .agents = $count else . end ]' \
    "$SESSIONS_FILE" > "${SESSIONS_FILE}.tmp" 2>/dev/null && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
fi
