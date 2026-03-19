#!/bin/bash
# Post-commit celebration — brief summary of what was shipped
# Hook type: PostToolUse (matcher: Bash)
set -uo pipefail

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")

# Only trigger on actual git commit commands
echo "$CMD" | grep -q "git commit" || exit 0

DIR=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
[ -z "$DIR" ] && exit 0

if cd "$DIR" 2>/dev/null; then
  SUBJECT=$(git log -1 --pretty=format:"%s" 2>/dev/null || echo "")
  FILES=$(git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | wc -l | tr -d ' ')
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  PROJ=$(basename "$DIR" 2>/dev/null || echo "Project")

  if [ -n "$SUBJECT" ]; then
    msg="Shipped: \"$SUBJECT\" — $FILES files on $BRANCH"
    osascript -e "display notification \"$msg\" with title \"$PROJ\" sound name \"Glass\"" 2>/dev/null || true
    jq -n --arg m "$msg" '{"systemMessage": $m}'
  fi
fi
