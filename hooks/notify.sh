#!/bin/bash
# Notification hook — context-aware macOS notifications with different sounds
# Hook type: Notification
set -uo pipefail

INPUT=$(cat)
MSG=$(echo "$INPUT" | jq -r '.message // "Task completed"' 2>/dev/null || echo "Task completed")
TYPE=$(echo "$INPUT" | jq -r '.type // ""' 2>/dev/null || echo "")

# Get project context
DIR=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
PROJ=$(basename "$DIR" 2>/dev/null || echo "Claude Code")

# Pick sound and title based on notification type
case "$TYPE" in
  permission_prompt)
    SOUND="Submarine"
    TITLE="$PROJ — Needs Approval"
    ;;
  idle_prompt)
    SOUND="Glass"
    TITLE="$PROJ — Ready"
    ;;
  auth_success)
    SOUND="Purr"
    TITLE="$PROJ — Authenticated"
    ;;
  *)
    SOUND="Glass"
    TITLE="$PROJ"
    ;;
esac

# Truncate long messages for notification
DISPLAY_MSG=$(echo "$MSG" | head -1 | cut -c1-100)

osascript -e "display notification \"$DISPLAY_MSG\" with title \"$TITLE\" sound name \"$SOUND\"" 2>/dev/null || true
