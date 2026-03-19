#!/bin/bash
# Session Start — session tracking + TTY mapping for Claude Monitor
# Hook type: SessionStart
set -uo pipefail

INPUT=$(cat)
DIR=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
[ -z "$DIR" ] && exit 0

# Reset session-scoped state
> "$HOME/.claude/.files_read" 2>/dev/null
echo "0" > "$HOME/.claude/.active_agents" 2>/dev/null
> "$HOME/.claude/.agent_activity" 2>/dev/null

# ── Map session_id -> TTY for Claude Monitor ──────────────
find_tty() {
  local current=$$
  for i in $(seq 1 15); do
    local parent=$(ps -p "$current" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$parent" ] || [ "$parent" = "1" ] && return
    local ptty=$(ps -p "$parent" -o tty= 2>/dev/null | tr -d ' ')
    if [ "$ptty" != "??" ] && [ -n "$ptty" ]; then
      echo "$ptty"; return
    fi
    current=$parent
  done
}

if [ -n "$SESSION_ID" ]; then
  MY_TTY=$(find_tty)
  [ -n "$MY_TTY" ] && echo "$SESSION_ID" > "$HOME/.claude/.tty_map_$MY_TTY" 2>/dev/null
fi

# ── Session tracking ──────────────────────────────────────
SESSIONS_FILE="$HOME/.claude/.sessions.json"
[ ! -f "$SESSIONS_FILE" ] && echo "[]" > "$SESSIONS_FILE"

if [ -n "$SESSION_ID" ]; then
  NOW=$(date +%s)
  PROJ=$(basename "$DIR" 2>/dev/null || echo "unknown")
  BRANCH=""
  if cd "$DIR" 2>/dev/null; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  fi

  # Remove stale sessions (>6h) and sessions from same dir, then add new one
  jq --arg id "$SESSION_ID" --arg proj "$PROJ" --arg branch "$BRANCH" \
     --arg dir "$DIR" --argjson now "$NOW" \
    '[ .[] | select(.id != $id and .dir != $dir and ($now - .lastActive) < 21600) ] + [{
      id: $id,
      project: $proj,
      branch: $branch,
      dir: $dir,
      started: $now,
      lastActive: $now,
      status: "active",
      agents: 0
    }]' "$SESSIONS_FILE" > "${SESSIONS_FILE}.tmp" 2>/dev/null && mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
fi

msg=""

# ── Handoff notes ─────────────────────────────────────────
if [ -f "$DIR/.claude/handoff.md" ]; then
  msg="Handoff notes from last session — read .claude/handoff.md to pick up where you left off."
fi

# ── Git status ────────────────────────────────────────────
if cd "$DIR" 2>/dev/null; then
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  if [ -n "$BRANCH" ]; then
    git_msg="Branch: $BRANCH"
    [ "$DIRTY" -gt 0 ] && git_msg="$git_msg — $DIRTY uncommitted changes"
    [ -n "$msg" ] && msg="$msg\n$git_msg" || msg="$git_msg"
  fi
fi

if [ -n "$msg" ]; then
  jq -n --arg m "$msg" '{"systemMessage": $m}'
fi
