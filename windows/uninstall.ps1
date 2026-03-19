# Claude Monitor — Windows Uninstaller
param([switch]$Force)

$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$HooksDir = Join-Path $ClaudeDir "hooks"

function Write-Ok($msg)   { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn($msg) { Write-Host "[!] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Info($msg)  { Write-Host "=> " -ForegroundColor Cyan -NoNewline; Write-Host $msg }

Write-Host ""
Write-Host "Claude Monitor — Uninstall" -ForegroundColor White
Write-Host ""

# ── Stop tray app ─────────────────────────────────────────
$procs = Get-Process -Name "powershell" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "tray-app\.ps1" }
if ($procs) {
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "Stopped Claude Monitor tray app"
}

# ── Remove startup shortcut ───────────────────────────────
$startupLnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ClaudeMonitor.lnk"
if (Test-Path $startupLnk) {
    Remove-Item $startupLnk -Force
    Write-Ok "Removed startup shortcut"
}

# ── Remove tray app + launcher ────────────────────────────
$trayApp = Join-Path $ClaudeDir "tray-app.ps1"
$launcher = Join-Path $ClaudeDir "ClaudeMonitor.bat"
if (Test-Path $trayApp) { Remove-Item $trayApp -Force; Write-Ok "Removed tray-app.ps1" }
if (Test-Path $launcher) { Remove-Item $launcher -Force; Write-Ok "Removed ClaudeMonitor.bat" }

# ── Remove hooks ─────────────────────────────────────────
$hooks = @(
    "insights.ps1", "session-start.ps1", "stop.ps1", "notify.ps1",
    "post-commit.ps1", "agent-start.ps1", "agent-stop.ps1",
    "track-reads.ps1", "read-before-edit.ps1", "pre-compact.ps1",
    "learn-from-failure.ps1"
)

$removed = 0
foreach ($hook in $hooks) {
    $path = Join-Path $HooksDir $hook
    if (Test-Path $path) {
        Remove-Item $path -Force
        $removed++
    }
}
Write-Ok "Removed $removed hooks"

# ── Clean up temp files ──────────────────────────────────
Write-Info "Cleaning up temporary files..."
$patterns = @(".ctx_*", ".state_*", ".ctxlog_*", ".tty_map_*", ".tty_resolved_*",
              ".activity_*", ".ctx_pct_*")
foreach ($pattern in $patterns) {
    Get-ChildItem -Path $ClaudeDir -Filter $pattern -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
$singleFiles = @(".files_read", ".active_agents", ".agent_activity",
                  ".session_names", ".sessions.json", ".usage_cache.json",
                  ".weekly_start_pct", ".build_failures.log")
foreach ($f in $singleFiles) {
    $path = Join-Path $ClaudeDir $f
    if (Test-Path $path) { Remove-Item $path -Force -ErrorAction SilentlyContinue }
}
Write-Ok "Cleaned up temporary files"

# ── Remove registry settings ─────────────────────────────
$regPath = "HKCU:\Software\ClaudeMonitor"
if (Test-Path $regPath) {
    Remove-Item $regPath -Recurse -Force
    Write-Ok "Removed registry settings"
}

Write-Host ""
Write-Warn "Note: settings.json was NOT modified."
Write-Warn "Remove the 'hooks' section manually if desired."
Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
