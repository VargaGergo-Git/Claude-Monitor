#!/bin/bash
# Safety gate: remind to read files before editing unfamiliar ones
# Hook type: PreToolUse (matcher: Edit|Write)
set -uo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Only for Edit and Write
case "$TOOL" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -z "$FILE" ] && exit 0

# Track which files have been read this session
READ_LOG="$HOME/.claude/.files_read"
touch "$READ_LOG" 2>/dev/null

# Check if this file was read before
if ! grep -qF "$FILE" "$READ_LOG" 2>/dev/null; then
  FNAME=$(basename "$FILE")
  jq -n --arg m "Editing $FNAME without reading it first — make sure you understand the full context." \
    '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": $m}}'
fi
