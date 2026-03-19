# Claude Monitor

A macOS menu bar app + hook system for monitoring Claude Code sessions in real time.

See what every session is doing, get notified when Claude needs your input, track API usage, and get human-readable descriptions of every tool call — all from your menu bar.

## What You Get

### Menu Bar App
- **Live session list** — see all active Claude Code sessions with project, branch, duration
- **State indicators** — green dot (working), amber dot (waiting for input), grey (idle)
- **AI-powered session names** — Haiku auto-names sessions based on what you asked ("Sleep Lab Redesign", "Fix Auth Bug")
- **Smart context summaries** — Haiku periodically summarizes what each session is doing right now
- **Context window tracking** — see how full each session's context is, get warned at 80%
- **API usage bars** — session (5-hour) and weekly utilization with reset timers
- **Branch conflict warnings** — alerts when multiple sessions share a branch, one-click split
- **macOS notifications** — when Claude finishes and needs your input
- **Click to jump** — click any session to switch to its Terminal tab
- **Wrap up sessions** — send `/done` or custom commands to any waiting session
- **Terminal tab renaming** — tabs auto-rename to match the AI-generated session name
- **Launch at login** — toggle from the Settings menu

### 11 Hooks
Human-readable narration and session intelligence, all via Claude Code's hook system:

| Hook | Event | What it does |
|------|-------|-------------|
| `insights.sh` | PreToolUse | Translates every tool call into plain English ("Investigating the sleep scoring engine") |
| `session-start.sh` | SessionStart | Maps sessions to Terminal tabs, tracks in JSON, shows git status |
| `stop.sh` | Stop | Marks session as "waiting", auto-saves dirty state to handoff.md |
| `notify.sh` | Notification | Context-aware macOS notifications with different sounds per type |
| `post-commit.sh` | PostToolUse | Celebrates commits with a notification showing what was shipped |
| `agent-start.sh` | SubagentStart | Tracks active sub-agents with descriptions |
| `agent-stop.sh` | SubagentStop | Decrements agent count, cleans activity log |
| `track-reads.sh` | PostToolUse | Logs which files Claude has read this session |
| `read-before-edit.sh` | PreToolUse | Warns if Claude tries to edit a file it hasn't read yet |
| `pre-compact.sh` | PreCompact | Reminds Claude to preserve key context before compression |
| `learn-from-failure.sh` | PostToolUseFailure | Logs build failures, nudges after 3+ consecutive errors |

### Status Line
A rich two-line status bar showing project, model, git branch, context usage, session/weekly API utilization, effort level, fast mode, and active agents — all color-coded with progress bars.

## Requirements

- macOS 14.0+ (Sonoma or later)
- Claude Code CLI
- `jq` (`brew install jq`)
- Xcode Command Line Tools (for building the app — `xcode-select --install`)
- Claude Code Max plan or API key with OAuth (for usage tracking + AI session names)

## Install

```bash
git clone https://github.com/vargagergo/claude-monitor.git
cd claude-monitor
chmod +x install.sh
./install.sh
```

This installs everything: menu bar app + all 11 hooks + status line + settings.

### Partial Install

```bash
# Hooks + statusline only (no menu bar app)
./install.sh --hooks

# Menu bar app only (no hooks)
./install.sh --app
```

### Manual Install

If you prefer to pick and choose:

1. Copy hooks you want to `~/.claude/hooks/`
2. Copy `statusline/statusline.sh` to `~/.claude/statusline.sh`
3. Merge hook entries from `settings-template.json` into your `~/.claude/settings.json`
4. Run `app/build.sh` to build and launch the menu bar app

## Uninstall

```bash
./uninstall.sh
```

Removes the app, hooks, statusline, and temp files. Your `settings.json` is left intact (with a note to remove hook entries manually).

## How It Works

### Session Discovery
The menu bar app scans running processes every 10 seconds, finding `claude` processes and mapping them to Terminal tabs via TTY. Session IDs are linked to TTYs by the hooks (specifically `insights.sh` and `session-start.sh`), which write `.tty_map_*` files that the app reads.

### State Tracking
- **Active**: `insights.sh` writes `active` to `.state_{session_id}` on every tool call
- **Waiting**: `stop.sh` writes `waiting` when Claude finishes a turn
- **Context %**: Both hooks capture `context_window.used_percentage` from the hook input

### AI Features (via Claude Haiku)
The app uses your existing Claude Code OAuth token to make lightweight Haiku API calls:
- **Session naming**: Reads the first user message from the session JSONL, asks Haiku for a 2-5 word title
- **Smart context**: Every 45 seconds, sends the last 6 tool actions + git diff stat to Haiku for a present-tense summary

Usage is tracked and shown in the menu ("Monitor: 12 Haiku calls, ~1,840 tok"). You can disable AI features in Settings > AI Session Names.

### Usage Tracking
The status line fetches your Claude API usage every 5 minutes via the OAuth API and caches it. The menu bar app reads this same cache file to show usage bars.

## File Structure

```
~/.claude/
├── ClaudeMonitor.app         # Menu bar app (built by installer)
├── statusline.sh             # Status line script
├── hooks/
│   ├── insights.sh           # PreToolUse — human-friendly narration
│   ├── session-start.sh      # SessionStart — session tracking
│   ├── stop.sh               # Stop — mark waiting, auto-handoff
│   ├── notify.sh             # Notification — macOS alerts
│   ├── post-commit.sh        # PostToolUse — commit celebration
│   ├── agent-start.sh        # SubagentStart — agent tracking
│   ├── agent-stop.sh         # SubagentStop — agent tracking
│   ├── track-reads.sh        # PostToolUse — file read tracking
│   ├── read-before-edit.sh   # PreToolUse — edit safety gate
│   ├── pre-compact.sh        # PreCompact — context reminder
│   └── learn-from-failure.sh # PostToolUseFailure — error logging
├── settings.json             # Claude Code config (hooks registered here)
│
│ # Temp files (auto-managed, cleaned after 24h):
├── .ctx_{sid}                # Last action description per session
├── .state_{sid}              # Session state (active/waiting)
├── .ctx_pct_{sid}            # Context window percentage
├── .ctxlog_{sid}             # Rolling action log (last 8)
├── .activity_{sid}           # Action timestamps for sparkline
├── .tty_map_{tty}            # TTY → session ID mapping
├── .tty_resolved_{sid}       # Flag: TTY already mapped
├── .session_names            # Cached AI-generated session names
├── .sessions.json            # Session tracking state
├── .usage_cache.json         # API usage cache (5min TTL)
├── .weekly_start_pct         # Weekly usage at start of day
├── .active_agents            # Current agent count
├── .agent_activity           # Active agent descriptions
├── .files_read               # Files read this session
└── .build_failures.log       # Recent build failure log
```

## Customization

### insights.sh — File Descriptions
The `describe_file()` function in `insights.sh` maps file paths to human-readable descriptions. Add your own project-specific patterns:

```bash
# In describe_file(), add cases like:
*MyApp/Screens/*) echo "a screen" ;;
*MyApp/Models/*)  echo "a data model" ;;
*MyApp/API/*)     echo "an API endpoint" ;;
```

### Notification Sounds
Edit `notify.sh` to change sounds per event type. Available sounds: `Tink`, `Glass`, `Submarine`, `Purr`, `Morse`, `Ping`, `Pop`, `Sosumi`.

### Status Line Colors
All colors in `statusline.sh` use RGB escape codes. Edit the palette section to match your terminal theme.

## Troubleshooting

**"No active sessions" even though Claude is running**
- The app finds sessions by looking for `claude` processes with a TTY. If you're using a non-standard terminal, the TTY mapping may not work.
- Start a new Claude Code session after installing — the hooks need to fire at least once to create the TTY mapping.

**Usage bars show 0%**
- The status line needs to fetch usage data. It caches for 5 minutes. If your OAuth token is expired, it will show 0%.
- Check: `security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken'`

**Hooks aren't firing**
- Verify hooks are in `settings.json`: `jq '.hooks' ~/.claude/settings.json`
- Check that hook scripts are executable: `ls -la ~/.claude/hooks/`
- Start a fresh Claude Code session (hooks are loaded at session start)

**App won't build**
- Ensure Xcode Command Line Tools are installed: `xcode-select --install`
- On Intel Macs, the installer auto-detects architecture

## License

MIT
