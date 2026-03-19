# Claude Monitor

A menu bar / system tray app + hook system for monitoring Claude Code sessions in real time. Works on **macOS** and **Windows**.

See what every session is doing, get notified when Claude needs your input, track API usage, and get human-readable descriptions of every tool call — all from your menu bar or system tray.

## Quick Install

**macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/VargaGergo-Git/Claude-Monitor/main/setup.sh | bash
```

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/VargaGergo-Git/Claude-Monitor/main/setup.ps1 | iex
```

## What You Get

### Menu Bar / System Tray App

Works on both **macOS** (native Swift menu bar app) and **Windows** (PowerShell system tray).

- **Live session list** — see all active Claude Code sessions with project, branch, duration
- **State indicators** — green dot (working), amber dot (waiting for input), grey (idle)
- **AI-powered session names** — Haiku auto-names sessions based on what you asked ("Sleep Lab Redesign", "Fix Auth Bug")
- **Smart context summaries** — Haiku periodically summarizes what each session is doing right now
- **Context window tracking** — see how full each session's context is, get warned at 80%
- **API usage bars** — session (5-hour) and weekly utilization with reset timers
- **Desktop notifications** — when Claude finishes and needs your input (macOS: osascript, Windows: toast)
- **Send commands** — type and send any message or command to a waiting session from the menu
- **Launch at login** — toggle from Settings (macOS: LaunchAgent, Windows: Startup folder)
- **Branch conflict warnings** — alerts when multiple sessions share a branch, one-click split (macOS)
- **Click to jump** — click any session to switch to its Terminal tab (macOS)
- **Terminal tab renaming** — tabs auto-rename to the AI-generated session name (macOS)

### 11 Hooks

Human-readable narration and session intelligence, all via Claude Code's hook system. Available as **bash** (`.sh`) for macOS/Linux and **PowerShell** (`.ps1`) for Windows.

| Hook | Event | What it does |
|------|-------|-------------|
| `insights` | PreToolUse | Translates every tool call into plain English ("Investigating the auth module") |
| `session-start` | SessionStart | Maps sessions to terminal tabs, tracks in JSON, shows git status |
| `stop` | Stop | Marks session as "waiting", auto-saves dirty state to handoff.md |
| `notify` | Notification | Context-aware desktop notifications with different sounds per type |
| `post-commit` | PostToolUse | Celebrates commits with a notification showing what was shipped |
| `agent-start` | SubagentStart | Tracks active sub-agents with descriptions |
| `agent-stop` | SubagentStop | Decrements agent count, cleans activity log |
| `track-reads` | PostToolUse | Logs which files Claude has read this session |
| `read-before-edit` | PreToolUse | Warns if Claude tries to edit a file it hasn't read yet |
| `pre-compact` | PreCompact | Reminds Claude to preserve key context before compression |
| `learn-from-failure` | PostToolUseFailure | Logs build failures, nudges after 3+ consecutive errors |

### Status Line

A rich multi-line status bar inside your Claude Code terminal. Available for both **macOS** (bash) and **Windows** (PowerShell).

Shows: project name, model, git branch + dirty indicator, context usage bar, session/weekly API utilization bars with reset timers, effort level, fast mode toggle, and active agent count — all color-coded with ANSI progress bars.

**No project needed to install.** You can set up Claude Monitor before your first Claude Code session — the app will show "No active sessions" and light up automatically once you start using Claude Code.

## Requirements

### macOS
- macOS 14.0+ (Sonoma or later)
- Claude Code CLI
- `jq` (`brew install jq`)
- Xcode Command Line Tools (for building the app — `xcode-select --install`)
- Claude Code Max plan or API key with OAuth (for usage tracking + AI session names)

### Windows
- Windows 10+
- PowerShell 5.1+ (included with Windows)
- Claude Code CLI
- `jq` (optional but recommended — `winget install jqlang.jq`)

## Install

### macOS

```bash
git clone https://github.com/VargaGergo-Git/Claude-Monitor.git
cd Claude-Monitor
chmod +x install.sh
./install.sh
```

This installs everything: menu bar app + all 11 hooks + status line + settings.

**Partial install:**
```bash
./install.sh --hooks   # Hooks + statusline only (no menu bar app)
./install.sh --app     # Menu bar app only (no hooks)
```

### Windows

```powershell
git clone https://github.com/VargaGergo-Git/Claude-Monitor.git
cd Claude-Monitor\windows
powershell -ExecutionPolicy Bypass -File install.ps1
```

This installs: system tray app + all 11 PowerShell hooks + settings.

**Partial install:**
```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode hooks   # Hooks only
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode app     # Tray app only
```

### Manual Install

If you prefer to pick and choose:

**macOS:**
1. Copy hooks you want to `~/.claude/hooks/`
2. Copy `statusline/statusline.sh` to `~/.claude/statusline.sh`
3. Merge hook entries from `settings-template.json` into your `~/.claude/settings.json`
4. Run `app/build.sh` to build and launch the menu bar app

**Windows:**
1. Copy `.ps1` hooks from `windows/hooks/` to `%USERPROFILE%\.claude\hooks\`
2. Merge hook entries from `windows/settings-template.json` into your settings
3. Copy `windows/tray-app.ps1` to `%USERPROFILE%\.claude\`
4. Run: `powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File %USERPROFILE%\.claude\tray-app.ps1`

## Uninstall

**macOS:**
```bash
./uninstall.sh
```

**Windows:**
```powershell
powershell -ExecutionPolicy Bypass -File windows\uninstall.ps1
```

Removes the app, hooks, and temp files. Your `settings.json` is left intact (with a note to remove hook entries manually).

## How It Works

### Session Discovery
**macOS:** The menu bar app scans running processes every 10 seconds, finding `claude` processes and mapping them to Terminal tabs via TTY. Session IDs are linked to TTYs by the hooks (specifically `insights.sh` and `session-start.sh`), which write `.tty_map_*` files that the app reads.

**Windows:** The PowerShell tray app reads `.state_*` and `.sessions.json` files written by the hooks. It also checks for Claude processes via `Get-CimInstance` and can detect sessions running in WSL.

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

### macOS
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

### Windows
```
%USERPROFILE%\.claude\
├── tray-app.ps1              # System tray app (PowerShell)
├── statusline.ps1            # Status line script (PowerShell)
├── ClaudeMonitor.bat         # Launcher script
├── hooks\
│   ├── insights.ps1          # PreToolUse — human-friendly narration
│   ├── session-start.ps1     # SessionStart — session tracking
│   ├── stop.ps1              # Stop — mark waiting, auto-handoff
│   ├── notify.ps1            # Notification — Windows toast alerts
│   ├── post-commit.ps1       # PostToolUse — commit celebration
│   ├── agent-start.ps1       # SubagentStart — agent tracking
│   ├── agent-stop.ps1        # SubagentStop — agent tracking
│   ├── track-reads.ps1       # PostToolUse — file read tracking
│   ├── read-before-edit.ps1  # PreToolUse — edit safety gate
│   ├── pre-compact.ps1       # PreCompact — context reminder
│   └── learn-from-failure.ps1 # PostToolUseFailure — error logging
│
│ # Same temp files as macOS (shared format)
├── .state_{sid}, .ctx_{sid}, .sessions.json, etc.
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

## Platform Differences

| Feature | macOS | Windows |
|---------|-------|---------|
| App type | Native Swift menu bar app | PowerShell system tray |
| AI session names | Yes (via Haiku API) | Yes (via Haiku API) |
| Smart context summaries | Yes (via Haiku API) | Yes (via Haiku API) |
| Terminal tab renaming | Yes (Apple Terminal) | Not yet |
| Status line | Yes (bash) | Yes (PowerShell) |
| Branch splitting | Yes (one-click) | Not yet |
| Toast notifications | Yes (via osascript) | Yes (via WinForms) |
| Session tracking | Yes | Yes |
| All 11 hooks | bash (.sh) | PowerShell (.ps1) |
| Launch at login | Yes (LaunchAgent) | Yes (Startup folder) |
| Credentials | macOS Keychain | Windows Credential Manager |

## Troubleshooting

### macOS

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

### Windows

**Tray app doesn't start**
- Make sure you're running with: `powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File tray-app.ps1`
- If your execution policy blocks scripts: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

**Hooks aren't firing**
- Verify hooks are in `settings.json`: `Get-Content ~/.claude/settings.json | ConvertFrom-Json | Select -Expand hooks`
- Make sure hook commands use the full `powershell -ExecutionPolicy Bypass -File ...` prefix
- Start a fresh Claude Code session

**Sessions not detected**
- The Windows tray app discovers sessions via `.state_*` files written by hooks. Hooks must fire at least once.
- If running Claude Code in WSL, the bash hooks from the `hooks/` directory work as-is — no need for the PowerShell versions.

**App won't build**
- Ensure Xcode Command Line Tools are installed: `xcode-select --install`
- On Intel Macs, the installer auto-detects architecture

## License

MIT
