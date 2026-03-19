#!/bin/bash
# Claude Code Insights — human-friendly narration of what Claude is doing
# Hook type: PreToolUse (fires before every tool call)
#
# This is the core hook that powers:
# 1. Human-readable status messages in Claude Code's output
# 2. Session state tracking for Claude Monitor (active/waiting)
# 3. Context window percentage tracking
# 4. Rolling action log for AI-powered context summaries
#
# CUSTOMIZATION: Edit describe_file() and describe_read_intent() to add
# project-specific file descriptions. The defaults cover common patterns.
set -uo pipefail

INPUT=$(cat)
# Extract tool name with sed first (jq may choke on regex in other fields)
TOOL=$(echo "$INPUT" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[ -z "$TOOL" ] && TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || echo "")

# Safe field accessor — tries jq first, falls back to sed for malformed JSON
get() {
  local v
  v=$(echo "$INPUT" | jq -r ".tool_input.${1} // \"\"" 2>/dev/null) && [ -n "$v" ] && echo "$v" && return
  echo "$INPUT" | sed -n "s/.*\"${1}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

msg=""

# ── Map session_id -> TTY for Claude Monitor (once per session) ──
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
if [ -n "$SESSION_ID" ] && [ ! -f "$HOME/.claude/.tty_resolved_$SESSION_ID" ]; then
  _current=$$
  for _i in $(seq 1 15); do
    _parent=$(ps -p "$_current" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$_parent" ] || [ "$_parent" = "1" ] && break
    _ptty=$(ps -p "$_parent" -o tty= 2>/dev/null | tr -d ' ')
    if [ "$_ptty" != "??" ] && [ -n "$_ptty" ]; then
      echo "$SESSION_ID" > "$HOME/.claude/.tty_map_$_ptty" 2>/dev/null
      touch "$HOME/.claude/.tty_resolved_$SESSION_ID" 2>/dev/null
      break
    fi
    _current=$_parent
  done
fi

# ── Map file paths to plain-English descriptions ─────────
# CUSTOMIZE: Add your own project-specific patterns here
describe_file() {
  local f="$1"
  case "$f" in
    *CLAUDE.md)                   echo "project rules" ;;
    *README.md)                   echo "project README" ;;
    *CHANGELOG.md)                echo "changelog" ;;
    *package.json)                echo "package config" ;;
    *Cargo.toml)                  echo "Cargo config" ;;
    *Gemfile)                     echo "Ruby dependencies" ;;
    *requirements.txt)            echo "Python dependencies" ;;
    *settings.json)               echo "settings" ;;
    *config*)                     echo "configuration" ;;
    *.test.*|*_test.*|*Tests*)    echo "tests for $(basename "$f" | sed 's/[._]test//; s/Tests//')" ;;
    *.spec.*)                     echo "specs for $(basename "$f" | sed 's/\.spec//')" ;;
    *migration*)                  echo "a database migration" ;;
    *.env*)                       echo "environment config" ;;
    *.swift)                      echo "$(basename "$f" .swift)" ;;
    *.ts|*.tsx)                   echo "$(basename "$f" | sed 's/\.[^.]*$//')" ;;
    *.py)                         echo "$(basename "$f" .py)" ;;
    *.rs)                         echo "$(basename "$f" .rs)" ;;
    *.go)                         echo "$(basename "$f" .go)" ;;
    *.rb)                         echo "$(basename "$f" .rb)" ;;
    *.md)                         echo "documentation" ;;
    *.sh)                         echo "a script" ;;
    *.png|*.jpg|*.jpeg|*.svg)     echo "an image" ;;
    *)                            echo "$(basename "$f")" ;;
  esac
}

describe_read_intent() {
  local f="$1" w
  w=$(describe_file "$f")
  case "$f" in
    *CLAUDE.md|*README*)          echo "Reviewing $w" ;;
    *config*|*settings*)          echo "Checking $w" ;;
    *Engine*|*Service*|*Manager*) echo "Investigating $w" ;;
    *Screen*|*View*|*Page*|*Component*) echo "Looking at $w" ;;
    *test*|*spec*|*Tests*)        echo "Reading $w" ;;
    *.png|*.jpg|*.jpeg|*.svg)     echo "Reviewing a screenshot" ;;
    *)                            echo "Reading $w" ;;
  esac
}

# ── Main dispatch ─────────────────────────────────────────
case "$TOOL" in

  Read)
    FILE=$(get file_path)
    msg=$(describe_read_intent "$FILE")
    ;;

  Edit)
    FILE=$(get file_path)
    WHAT=$(describe_file "$FILE")
    OLD_LEN=$(get old_string | wc -c | tr -d ' ')
    NEW_LEN=$(get new_string | wc -c | tr -d ' ')
    RA=$(get replace_all)

    if [ "$RA" = "true" ]; then
      msg="Renaming across $WHAT"
    elif [ "$NEW_LEN" -le 1 ] 2>/dev/null; then
      msg="Removing code from $WHAT"
    elif [ "$OLD_LEN" -lt 10 ] 2>/dev/null && [ "$NEW_LEN" -gt 100 ] 2>/dev/null; then
      msg="Adding new functionality to $WHAT"
    elif [ "$NEW_LEN" -gt "$OLD_LEN" ] 2>/dev/null; then
      msg="Expanding $WHAT"
    elif [ "$OLD_LEN" -gt "$NEW_LEN" ] 2>/dev/null; then
      msg="Simplifying $WHAT"
    else
      msg="Tweaking $WHAT"
    fi
    ;;

  Write)
    FILE=$(get file_path)
    WHAT=$(describe_file "$FILE")
    LINES=$(get content | wc -l | tr -d ' ')
    [ "$LINES" -gt 100 ] 2>/dev/null && msg="Creating $WHAT (${LINES} lines)" || msg="Creating $WHAT"
    ;;

  Bash)
    CMD=$(get command)
    BASE=$(echo "$CMD" | awk '{print $1}' | sed 's|.*/||')
    case "$BASE" in
      git)
        SUB=$(echo "$CMD" | awk '{print $2}')
        case "$SUB" in
          status)   msg="Checking what files have changed" ;;
          diff)     msg="Reviewing the actual changes" ;;
          log)      msg="Looking at recent commit history" ;;
          commit)   msg="Saving changes as a commit" ;;
          push)     msg="Pushing changes to remote" ;;
          pull)     msg="Pulling latest from remote" ;;
          checkout) msg="Switching branches" ;;
          branch)   msg="Working with branches" ;;
          stash)    msg="Temporarily shelving changes" ;;
          merge)    msg="Merging branches together" ;;
          rebase)   msg="Reorganizing commit history" ;;
          add)      msg="Staging files for commit" ;;
          *)        msg="Git operation" ;;
        esac ;;
      xcodebuild)
        if echo "$CMD" | grep -q ' test'; then
          msg="Running tests"
        elif echo "$CMD" | grep -q ' build'; then
          msg="Building the project"
        elif echo "$CMD" | grep -q ' clean'; then
          msg="Cleaning previous build"
        else
          msg="Xcode build operation"
        fi ;;
      npm|yarn|pnpm)
        SUB=$(echo "$CMD" | awk '{print $2}')
        case "$SUB" in
          install|add|i) msg="Installing dependencies" ;;
          run)           msg="Running $(echo "$CMD" | awk '{print $3}')" ;;
          test)          msg="Running tests" ;;
          build)         msg="Building the project" ;;
          *)             msg="Package manager: $SUB" ;;
        esac ;;
      cargo)
        SUB=$(echo "$CMD" | awk '{print $2}')
        case "$SUB" in
          build) msg="Building with Cargo" ;;
          test)  msg="Running Cargo tests" ;;
          run)   msg="Running the project" ;;
          *)     msg="Cargo: $SUB" ;;
        esac ;;
      python3|python) msg="Running a Python script" ;;
      make)    msg="Running make" ;;
      docker)  msg="Docker operation" ;;
      rm)      msg="Cleaning up files" ;;
      ls)      msg="Checking directory contents" ;;
      mkdir)   msg="Setting up a new folder" ;;
      chmod)   msg="Making a file executable" ;;
      open)    msg="Opening in Finder/app" ;;
      curl)    msg="Fetching something from the web" ;;
      jq)      msg="Validating JSON structure" ;;
      *)       msg="Running a command" ;;
    esac
    ;;

  Glob)
    PAT=$(get pattern)
    case "$PAT" in
      *test*|*spec*|*Test*) msg="Finding test files" ;;
      *.swift)  msg="Finding Swift files" ;;
      *.ts|*.tsx) msg="Finding TypeScript files" ;;
      *.py)     msg="Finding Python files" ;;
      *.rs)     msg="Finding Rust files" ;;
      *.go)     msg="Finding Go files" ;;
      *.md)     msg="Finding documentation" ;;
      *)        msg="Searching for files" ;;
    esac
    ;;

  Grep)
    PAT=$(echo "$INPUT" | sed -n 's/.*"pattern"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | cut -c1-40)
    case "$PAT" in
      *TODO*|*FIXME*|*HACK*)              msg="Looking for known issues in the code" ;;
      *import*)                           msg="Checking dependencies" ;;
      *func\ *|*function\ *|*def\ *)     msg="Finding a function definition" ;;
      *class\ *|*struct\ *|*interface\ *) msg="Finding a type definition" ;;
      *error*|*Error*|*crash*|*fatal*)    msg="Hunting for error-prone code" ;;
      *)                                  msg="Searching code for \"${PAT}\"" ;;
    esac
    ;;

  Agent)
    DESC=$(get description)
    BG=$(get run_in_background)
    if [ -n "$DESC" ]; then
      [ "$BG" = "true" ] && msg="Background task: $DESC" || msg="Sub-task: $DESC"
    else
      msg="Launching a helper agent"
    fi
    ;;

  Skill)
    SK=$(get skill)
    case "$SK" in
      commit)   msg="Preparing to save your changes" ;;
      plan)     msg="Drawing up an implementation plan" ;;
      *)        msg="Running /$SK" ;;
    esac
    ;;

  WebFetch)
    DOMAIN=$(get url | sed -E 's|https?://([^/]+).*|\1|')
    msg="Reading a page from $DOMAIN"
    ;;

  WebSearch)
    Q=$(get query | cut -c1-50)
    msg="Searching the web: $Q"
    ;;

  # Xcode Build MCP tools
  mcp__XcodeBuildMCP__build_sim|mcp__XcodeBuildMCP__build_run_sim)
    msg="Building and launching the app" ;;
  mcp__XcodeBuildMCP__test_sim)
    msg="Running tests on the simulator" ;;
  mcp__XcodeBuildMCP__screenshot)
    msg="Taking a screenshot of the app" ;;
  mcp__XcodeBuildMCP__snapshot_ui)
    msg="Inspecting the app's UI layout" ;;
  mcp__XcodeBuildMCP__session_show_defaults)
    msg="Checking build configuration" ;;
  mcp__XcodeBuildMCP__clean)
    msg="Cleaning build files" ;;

  *)
    echo "$TOOL" | grep -q "^mcp__" && msg="Using an external tool"
    ;;
esac

# ── Claude Monitor data ──────────────────────────────────
# SESSION_ID already extracted at top of script
if [ -n "$SESSION_ID" ]; then
  # Write last action
  [ -n "$msg" ] && echo "$msg" > "$HOME/.claude/.ctx_$SESSION_ID" 2>/dev/null

  # Mark session as ACTIVE (Claude is working)
  echo "active" > "$HOME/.claude/.state_$SESSION_ID" 2>/dev/null

  # Append to rolling context log (last 8 actions, for Haiku summarization)
  if [ -n "$msg" ]; then
    LOG="$HOME/.claude/.ctxlog_$SESSION_ID"
    echo "$msg" >> "$LOG" 2>/dev/null
    tail -8 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG" 2>/dev/null
  fi

  # Capture context window percentage
  CTX_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // empty' 2>/dev/null || echo "")
  [ -n "$CTX_PCT" ] && echo "$CTX_PCT" > "$HOME/.claude/.ctx_pct_$SESSION_ID" 2>/dev/null

  # Track action timestamps for activity sparkline (epoch seconds, last 20)
  ACTIVITY_LOG="$HOME/.claude/.activity_$SESSION_ID"
  date +%s >> "$ACTIVITY_LOG" 2>/dev/null
  tail -20 "$ACTIVITY_LOG" > "${ACTIVITY_LOG}.tmp" 2>/dev/null && mv "${ACTIVITY_LOG}.tmp" "$ACTIVITY_LOG" 2>/dev/null
fi

[ -n "$msg" ] && jq -n --arg m "$msg" '{"systemMessage": $m}' || true
