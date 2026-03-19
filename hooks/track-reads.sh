#!/bin/bash
# Track which files have been read (for read-before-edit gate)
# Hook type: PostToolUse (matcher: Read)
set -uo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

[ "$TOOL" != "Read" ] && exit 0

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -z "$FILE" ] && exit 0

READ_LOG="$HOME/.claude/.files_read"
echo "$FILE" >> "$READ_LOG" 2>/dev/null
