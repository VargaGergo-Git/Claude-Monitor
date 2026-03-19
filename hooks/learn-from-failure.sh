#!/bin/bash
# Self-healing: after a failed build or tool error, log the lesson
# Hook type: PostToolUseFailure (matcher: Bash)
set -uo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""' 2>/dev/null || echo "")

# Only act on tool failures that might contain build errors
case "$TOOL" in
  Bash) ;;
  *) exit 0 ;;
esac

# Check if the response contains build errors
ERROR_MATCH=""
if echo "$RESPONSE" | grep -qi "error:"; then
  ERROR_MATCH=$(echo "$RESPONSE" | grep -i "error:" | head -3 | sed 's/"/\\"/g' | tr '\n' ' ' | cut -c1-300)
elif echo "$RESPONSE" | grep -qi "failed"; then
  ERROR_MATCH=$(echo "$RESPONSE" | grep -i "failed" | head -2 | sed 's/"/\\"/g' | tr '\n' ' ' | cut -c1-200)
fi

[ -z "$ERROR_MATCH" ] && exit 0

# Log the failure for review
LESSONS="$HOME/.claude/.build_failures.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M')
echo "[$TIMESTAMP] $ERROR_MATCH" >> "$LESSONS" 2>/dev/null

# Count recent failures
RECENT=$(tail -20 "$LESSONS" 2>/dev/null | wc -l | tr -d ' ')

if [ "$RECENT" -ge 3 ]; then
  jq -n --arg m "Build has failed $RECENT times recently. Check ~/.claude/.build_failures.log for patterns." \
    '{"systemMessage": $m}'
fi
