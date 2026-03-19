#!/bin/bash
# Track active agents — count + descriptions + session tracking
# Hook type: SubagentStart
set -uo pipefail

INPUT=$(cat)
COUNTER="$HOME/.claude/.active_agents"
AGENTS_FILE="$HOME/.claude/.agent_activity"
SESSIONS_FILE="$HOME/.claude/.sessions.json"

# Increment count
CURRENT=$(cat "$COUNTER" 2>/dev/null || echo "0")
NEW_COUNT=$((CURRENT + 1))
echo "$NEW_COUNT" > "$COUNTER"

# Try to capture agent description
DESC=$(echo "$INPUT" | jq -r '.agent_name // .tool_input.description // ""' 2>/dev/null || echo "")
[ -z "$DESC" ] && DESC=$(echo "$INPUT" | sed -n 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$DESC" ] && DESC="working"

# Append to activity log with timestamp
TS=$(date +%s)
echo "${TS}|${DESC}" >> "$AGENTS_FILE" 2>/dev/null

# Update session agent count
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
if [ -n "$SESSION_ID" ] && [ -f "$SESSIONS_FILE" ]; then
  jq --arg id "$SESSION_ID" --argjson count "$NEW_COUNT" \
    '[ .[] | if .id == $id then .agents = $count | .status = "active" else . end ]' \
    "$SESSIONS_FILE" > "${SESSIONS_FILE}.tmp" 2>/dev/null && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
fi
