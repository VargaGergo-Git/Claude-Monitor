# Claude Monitor -- Windows Installer
# Usage: powershell -ExecutionPolicy Bypass -File install.ps1
#        powershell -ExecutionPolicy Bypass -File install.ps1 -Mode hooks
#        powershell -ExecutionPolicy Bypass -File install.ps1 -Mode app
param(
    [ValidateSet("full", "hooks", "app")]
    [string]$Mode = "full"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$HooksDir = Join-Path $ClaudeDir "hooks"
$Settings = Join-Path $ClaudeDir "settings.json"

function Write-Info($msg)  { Write-Host "=> " -ForegroundColor Cyan -NoNewline; Write-Host $msg }
function Write-Ok($msg)    { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Warn($msg)  { Write-Host "[!] " -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Write-Err($msg)   { Write-Host "[X] " -ForegroundColor Red -NoNewline; Write-Host $msg }

Write-Host ""
Write-Host "Claude Monitor" -ForegroundColor White -NoNewline
Write-Host " -- System tray app + hooks for Claude Code" -ForegroundColor Gray
Write-Host ""

# -- Prerequisites -----------------------------------------
if (-not (Get-Command "jq" -ErrorAction SilentlyContinue)) {
    Write-Warn "jq not found. Some hooks use jq for JSON parsing."
    Write-Warn "Install with: winget install jqlang.jq"
    Write-Host ""
}

# Create directories
New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
New-Item -ItemType Directory -Path $HooksDir -Force | Out-Null

# -- Install hooks -----------------------------------------
function Install-Hooks {
    Write-Info "Installing PowerShell hooks to $HooksDir..."

    $hooks = @(
        "insights.ps1",
        "session-start.ps1",
        "stop.ps1",
        "notify.ps1",
        "post-commit.ps1",
        "agent-start.ps1",
        "agent-stop.ps1",
        "track-reads.ps1",
        "read-before-edit.ps1",
        "pre-compact.ps1",
        "learn-from-failure.ps1"
    )

    $installed = 0
    $skipped = 0

    foreach ($hook in $hooks) {
        $src = Join-Path $ScriptDir "hooks\$hook"
        $dst = Join-Path $HooksDir $hook

        if (-not (Test-Path $src)) {
            Write-Warn "Source not found: $src"
            continue
        }

        if (Test-Path $dst) {
            if ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash) {
                $skipped++
                continue
            }
            Copy-Item $dst "$dst.backup" -Force
            Write-Warn "Backed up existing $hook"
        }

        Copy-Item $src $dst -Force
        $installed++
    }

    Write-Ok "Hooks: $installed installed, $skipped already up-to-date"
}

# -- Install statusline -----------------------------------
function Install-Statusline {
    Write-Info "Installing statusline..."

    $src = Join-Path $ScriptDir "statusline.ps1"
    $dst = Join-Path $ClaudeDir "statusline.ps1"

    if (-not (Test-Path $src)) {
        Write-Warn "statusline.ps1 not found -- skipping"
        return
    }

    if ((Test-Path $dst) -and (Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash) {
        Write-Ok "Statusline already up-to-date"
        return
    }

    if (Test-Path $dst) {
        Copy-Item $dst "$dst.backup" -Force
        Write-Warn "Backed up existing statusline.ps1"
    }

    Copy-Item $src $dst -Force
    Write-Ok "Statusline installed"
}

# -- Configure settings.json ------------------------------
function Configure-Settings {
    Write-Info "Configuring settings.json..."

    $templatePath = Join-Path $ScriptDir "settings-template.json"
    if (-not (Test-Path $templatePath)) {
        Write-Warn "settings-template.json not found -- skipping settings configuration"
        return
    }

    if (-not (Test-Path $Settings)) {
        # Create new settings from template
        $template = Get-Content $templatePath -Raw | ConvertFrom-Json
        # Remove comment fields
        $template.PSObject.Properties.Remove('_comment')
        $template.PSObject.Properties.Remove('_instructions')
        $template | ConvertTo-Json -Depth 10 | Set-Content $Settings
        Write-Ok "Created settings.json with hooks configuration"
        return
    }

    # Check if hooks already configured
    $existing = $null
    try {
        $raw = Get-Content $Settings -Raw -ErrorAction Stop
        if ($raw) { $existing = $raw | ConvertFrom-Json }
    } catch {}

    if (-not $existing) {
        # settings.json is empty or invalid -- create from template
        $template = Get-Content $templatePath -Raw | ConvertFrom-Json
        $template.PSObject.Properties.Remove('_comment')
        $template.PSObject.Properties.Remove('_instructions')
        $template | ConvertTo-Json -Depth 10 | Set-Content $Settings
        Write-Ok "Created settings.json from template (previous file was empty/invalid)"
        return
    }

    if ($existing.hooks) {
        Write-Warn "Hooks already configured in settings.json -- not overwriting"
        Write-Warn "Compare with windows/settings-template.json to see what's new"
        return
    }

    # Merge hooks + statusLine into existing settings
    $backup = "$Settings.pre-monitor-backup"
    Copy-Item $Settings $backup -Force

    $template = Get-Content $templatePath -Raw | ConvertFrom-Json
    $existing | Add-Member -NotePropertyName "hooks" -NotePropertyValue $template.hooks -Force
    if ($template.statusLine) {
        $existing | Add-Member -NotePropertyName "statusLine" -NotePropertyValue $template.statusLine -Force
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content $Settings

    Write-Ok "Merged hooks + statusline into settings.json"
    Write-Ok "Backup saved to $backup"
}

# -- Install tray app -------------------------------------
function Install-App {
    Write-Info "Installing Claude Monitor tray app..."

    $src = Join-Path $ScriptDir "tray-app.ps1"
    $dst = Join-Path $ClaudeDir "tray-app.ps1"

    if (-not (Test-Path $src)) {
        Write-Err "tray-app.ps1 not found"
        return
    }

    Copy-Item $src $dst -Force
    Write-Ok "Tray app installed to $dst"

    # Create a launcher batch file for easy startup
    $launcher = Join-Path $ClaudeDir "ClaudeMonitor.bat"
    @"
@echo off
start /min powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File "%USERPROFILE%\.claude\tray-app.ps1"
"@ | Set-Content $launcher

    Write-Ok "Launcher created: $launcher"

    # Launch it
    Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dst`"" -WindowStyle Hidden
    Write-Ok "Claude Monitor is running in your system tray"
}

# -- Execute -----------------------------------------------
switch ($Mode) {
    "full" {
        Install-Hooks
        Install-Statusline
        Configure-Settings
        Install-App
    }
    "hooks" {
        Install-Hooks
        Install-Statusline
        Configure-Settings
    }
    "app" {
        Install-App
    }
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""

if ($Mode -ne "app") {
    Write-Host "What was installed:"
    Write-Host "  Hooks (11)     $HooksDir"
    Write-Host "  Statusline     $ClaudeDir\statusline.ps1"
    Write-Host "  Settings       $Settings"
    Write-Host ""
}

if ($Mode -ne "hooks") {
    Write-Host "  Tray app       $ClaudeDir\tray-app.ps1"
    Write-Host "  Launcher       $ClaudeDir\ClaudeMonitor.bat"
    Write-Host ""
    Write-Host "Launch at login: toggle in the tray app's Settings menu"
}

Write-Host ""
Write-Host "Start a new Claude Code session to see everything in action."
