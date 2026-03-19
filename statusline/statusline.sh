#!/bin/bash
# Claude Code Status Line — rich terminal status bar with usage tracking
# Shows: project, model, git branch, context %, session/weekly usage, active agents
#
# Add to your ~/.claude/settings.json:
# "statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "padding": 4 }
set -euo pipefail

INPUT=$(cat)

# ── Parse ───────────────────────────────────────────────────
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "Claude"')
EFFORT=$(jq -r '.effortLevel // "default"' "$HOME/.claude/settings.json" 2>/dev/null || echo "default")
PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DIR=$(echo "$INPUT" | jq -r '.workspace.current_dir // ""')
PROJ=$(basename "$DIR" 2>/dev/null || echo "")

# ── Git ─────────────────────────────────────────────────────
BRANCH=$(cd "$DIR" 2>/dev/null && git branch --show-current 2>/dev/null || echo "")
DIRTY=$(cd "$DIR" 2>/dev/null && git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# ── Fetch plan usage (cached 5min) ──────────────────────────
CACHE="$HOME/.claude/.usage_cache.json"
CACHE_AGE=999
if [ -f "$CACHE" ]; then
  CACHE_MOD=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  CACHE_AGE=$((NOW - CACHE_MOD))
fi

if [ "$CACHE_AGE" -ge 300 ]; then
  TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken' 2>/dev/null || echo "")
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    RESP=$(curl -s --max-time 3 \
      -H "Authorization: Bearer $TOKEN" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || echo "")
    if echo "$RESP" | jq -e '.five_hour' >/dev/null 2>&1; then
      echo "$RESP" > "$CACHE"
    else
      # Touch cache to prevent retry spam on rate limit
      touch "$CACHE" 2>/dev/null
    fi
  fi
fi

# ── Parse usage ─────────────────────────────────────────────
SESSION_PCT=0; WEEKLY_PCT=0
SESS_RESET=""; WEEK_RESET=""; WEEK_DELTA=0

if [ -f "$CACHE" ]; then
  SESSION_PCT=$(jq -r '.five_hour.utilization // 0' "$CACHE" | cut -d. -f1)
  WEEKLY_PCT=$(jq -r '.seven_day.utilization // 0' "$CACHE" | cut -d. -f1)

  WEEK_START_FILE="$HOME/.claude/.weekly_start_pct"
  if [ ! -f "$WEEK_START_FILE" ]; then
    echo "$WEEKLY_PCT" > "$WEEK_START_FILE"
  fi
  WEEK_START_PCT=$(cat "$WEEK_START_FILE" 2>/dev/null || echo "$WEEKLY_PCT")
  WEEK_DELTA=$((WEEKLY_PCT - WEEK_START_PCT))
  [ "$WEEK_DELTA" -lt 0 ] && WEEK_DELTA=0

  SESS_TS=$(jq -r '.five_hour.resets_at // ""' "$CACHE")
  if [ -n "$SESS_TS" ] && [ "$SESS_TS" != "null" ]; then
    RESET_EPOCH=$(python3 -c "
from datetime import datetime, timezone
ts = '$SESS_TS'.split('.')[0]
try:
    dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except: print(0)
" 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    REM=$((RESET_EPOCH - NOW_EPOCH))
    if [ "$REM" -gt 0 ]; then
      RH=$((REM / 3600)); RM=$(( (REM % 3600) / 60 ))
      SESS_RESET="${RH}h${RM}m"
    fi
  fi

  WEEK_TS=$(jq -r '.seven_day.resets_at // ""' "$CACHE")
  if [ -n "$WEEK_TS" ] && [ "$WEEK_TS" != "null" ]; then
    WEEK_RESET=$(python3 -c "
from datetime import datetime, timezone
ts = '$WEEK_TS'.split('.')[0]
try:
    dt = datetime.strptime(ts, '%Y-%m-%dT%H:%M:%S').replace(tzinfo=timezone.utc)
    local = dt.astimezone()
    print(local.strftime('%a %-H:%M'))
except: pass
" 2>/dev/null || echo "")
  fi
fi

# ── Palette ─────────────────────────────────────────────────
R="\033[0m"; D="\033[2m"; B="\033[1m"

FG_BRAND="\033[38;2;255;150;70m"
FG_MODEL="\033[38;2;200;195;185m"
FG_PROJ="\033[38;2;235;235;248m"
FG_GIT="\033[38;2;100;220;195m"
FG_DIRTY="\033[38;2;255;190;70m"
FG_OK="\033[38;2;120;220;155m"
FG_MID="\033[38;2;245;195;75m"
FG_HOT="\033[38;2;245;115;100m"
FG_DIM="\033[38;2;80;80;105m"
FG_MUTED="\033[38;2;42;42;55m"
FG_EFF_LO="\033[38;2;90;200;160m"
FG_EFF_MED="\033[38;2;220;195;90m"
FG_EFF_HI="\033[38;2;240;130;90m"
FG_SESS="\033[38;2;175;145;240m"
FG_WEEK="\033[38;2;105;175;245m"
FG_SEP="\033[38;2;45;45;62m"
FG_CTX="\033[38;2;140;210;180m"

BG="\033[48;2;18;18;26m"

# ── Helpers ─────────────────────────────────────────────────
pick_usage_fg() {
  local p=$1 label_color=$2
  if   [ "$p" -ge 80 ]; then echo -n "$FG_HOT"
  elif [ "$p" -ge 50 ]; then echo -n "$FG_MID"
  else                        echo -n "$label_color"
  fi
}

make_bar() {
  local p=$1 n=$2 fg=$3
  local f=$((p * n / 100))
  [ "$f" -gt "$n" ] && f=$n
  local filled="" empty=""
  for i in $(seq 1 "$f"); do filled="${filled}━"; done
  for i in $(seq 1 $((n - f))); do empty="${empty}─"; done
  echo -n "${fg}${filled}${FG_MUTED}${empty}"
}

SEP="${FG_SEP} │ ${R}${BG}"

# ── Effort ──────────────────────────────────────────────────
case "$EFFORT" in
  low|min)   EFF_FG="$FG_EFF_LO";  EFF_LABEL="Low" ;;
  high|max)  EFF_FG="$FG_EFF_HI";  EFF_LABEL="High" ;;
  medium)    EFF_FG="$FG_EFF_MED"; EFF_LABEL="Medium" ;;
  *)         EFF_FG="$FG_DIM";     EFF_LABEL="" ;;
esac

# ── Fast Mode ────────────────────────────────────────────
FAST=$(jq -r '.fastMode // false' "$HOME/.claude/settings.json" 2>/dev/null || echo "false")
FG_FAST_ON="\033[38;2;255;150;70m"
FG_FAST_OFF="\033[38;2;80;80;105m"

# ── Line 1: Project + Model + Git + Context ─────────────────
L1="${BG} "

L1="${L1}${FG_BRAND}${B}◆${R}${BG} ${FG_PROJ}${B}${PROJ}${R}${BG} ${FG_DIM}·${R}${BG} ${FG_MODEL}${MODEL}${R}${BG}"

if [ -n "$BRANCH" ]; then
  L1="${L1}${SEP}${FG_GIT}${BRANCH}${R}${BG}"
  [ "$DIRTY" -gt 0 ] && L1="${L1} ${FG_DIRTY}●${R}${BG}"
fi

# Context bar
CTX_FG=$(pick_usage_fg "$PCT" "$FG_CTX")
CTX_BAR=$(make_bar "$PCT" 20 "$CTX_FG")
L1="${L1}${SEP}${FG_DIM}context${R}${BG} ${CTX_BAR}${R}${BG} ${CTX_FG}${B}${PCT}%${R}${BG}"

[ -n "$EFF_LABEL" ] && L1="${L1}${SEP}${EFF_FG}${EFF_LABEL}${R}${BG}"

if [ "$FAST" = "true" ]; then
  L1="${L1}${SEP}${FG_FAST_ON}${B}⚡Fast${R}${BG}"
else
  L1="${L1}${SEP}${FG_FAST_OFF}⚡Off${R}${BG}"
fi

L1="${L1} ${R}"

# ── Line 2: Session + Weekly usage ──────────────────────────
L2="${BG} "

# Session
SESS_FG=$(pick_usage_fg "$SESSION_PCT" "$FG_SESS")
SESS_BAR=$(make_bar "$SESSION_PCT" 24 "$SESS_FG")
L2="${L2}${FG_SESS}Session${R}${BG} ${SESS_BAR}${R}${BG} ${SESS_FG}${B}${SESSION_PCT}%${R}${BG}"
[ -n "$SESS_RESET" ] && L2="${L2} ${FG_DIM}${SESS_RESET}${R}${BG}"

# Weekly
WEEK_FG=$(pick_usage_fg "$WEEKLY_PCT" "$FG_WEEK")
WEEK_BAR=$(make_bar "$WEEKLY_PCT" 24 "$WEEK_FG")
L2="${L2}${SEP}${FG_WEEK}Weekly${R}${BG} ${WEEK_BAR}${R}${BG} ${WEEK_FG}${B}${WEEKLY_PCT}%${R}${BG}"
if [ "$WEEK_DELTA" -gt 0 ]; then
  L2="${L2} ${FG_DIM}+${WEEK_DELTA}%${R}${BG}"
fi
[ -n "$WEEK_RESET" ] && L2="${L2} ${FG_DIM}${WEEK_RESET}${R}${BG}"

# Last refreshed marker
if [ -f "$CACHE" ]; then
  CACHE_MOD2=$(stat -f %m "$CACHE" 2>/dev/null || echo 0)
  NOW2=$(date +%s)
  AGO=$(( NOW2 - CACHE_MOD2 ))
  if [ "$AGO" -lt 60 ]; then
    REFRESH_LABEL="just now"
  elif [ "$AGO" -lt 3600 ]; then
    REFRESH_LABEL="$((AGO / 60))m ago"
  else
    REFRESH_LABEL="$((AGO / 3600))h ago"
  fi
  L2="${L2} ${FG_DIM}· ${REFRESH_LABEL}${R}${BG}"
fi

L2="${L2} ${R}"

# ── Active Agents line (only shown when agents are running) ──
AGENTS=$(cat "$HOME/.claude/.active_agents" 2>/dev/null || echo "0")
FG_AGENT="\033[38;2;180;140;255m"
FG_AGENT_TASK="\033[38;2;130;110;180m"
AGENTS_FILE="$HOME/.claude/.agent_activity"

AGENT_LINE=""
if [ "$AGENTS" -gt 0 ] 2>/dev/null; then
  AGENT_DESCS=""
  if [ -f "$AGENTS_FILE" ]; then
    while IFS='|' read -r ts desc; do
      [ -z "$desc" ] && continue
      SHORT=$(echo "$desc" | cut -c1-25)
      if [ -n "$AGENT_DESCS" ]; then
        AGENT_DESCS="${AGENT_DESCS}, ${SHORT}"
      else
        AGENT_DESCS="$SHORT"
      fi
    done < "$AGENTS_FILE"
  fi

  AGENT_SUFFIX=""; [ "$AGENTS" -gt 1 ] && AGENT_SUFFIX="s"
  AGENT_LINE="${BG} ${FG_AGENT}${B}◆ ${AGENTS} agent${AGENT_SUFFIX}${R}${BG}"
  [ -n "$AGENT_DESCS" ] && AGENT_LINE="${AGENT_LINE} ${FG_AGENT_TASK}${AGENT_DESCS}${R}${BG}"

  if [ "$SESSION_PCT" -gt 0 ] 2>/dev/null; then
    AGENT_LINE="${AGENT_LINE} ${FG_DIM}· session ${SESSION_PCT}% used${R}${BG}"
  fi

  AGENT_LINE="${AGENT_LINE} ${R}"
fi

# ── Output ──────────────────────────────────────────────────
echo -e "$L1"
echo -e "$L2"
if [ -n "$AGENT_LINE" ]; then
  echo -e "$AGENT_LINE"
fi
