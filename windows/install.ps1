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

# Write settings.json in UTF-8 (no BOM). PS 5.1's Set-Content defaults to
# ANSI encoding, which corrupts Unicode chars like o-double-acute when
# Node.js reads as UTF-8.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
function Write-SettingsJson($content) {
    [System.IO.File]::WriteAllText($Settings, $content, $Utf8NoBom)
}

# Generate an EncodedCommand that runs a script via $env:USERPROFILE.
# This avoids passing Unicode chars (like o-double-acute in Hungarian usernames)
# through cmd.exe, which corrupts them and breaks hook paths.
function Get-EncodedHookCmd($relPath) {
    $script = "& (Join-Path `$env:USERPROFILE '$relPath')"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    return "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

# Convert all hook/statusLine commands from -File to -EncodedCommand.
# This is the key fix for Unicode usernames on Windows.
function ConvertTo-SafeCommands($config) {
    if ($config.hooks) {
        foreach ($eventProp in $config.hooks.PSObject.Properties) {
            foreach ($group in $eventProp.Value) {
                foreach ($h in $group.hooks) {
                    if ($h.command -match '\\hooks\\([^\\]+\.ps1)') {
                        $h.command = Get-EncodedHookCmd ".claude\hooks\$($matches[1])"
                    }
                }
            }
        }
    }
    if ($config.statusLine -and $config.statusLine.command -match 'statusline\.ps1') {
        $config.statusLine.command = Get-EncodedHookCmd '.claude\statusline.ps1'
    }
}

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

# Clean up old ANSI-encoded session data (Unicode fix)
$oldSessions = Join-Path $ClaudeDir ".sessions.json"
if (Test-Path $oldSessions) {
    $raw = Get-Content $oldSessions -Raw -ErrorAction SilentlyContinue
    if ($raw -and $raw -match '[^\x00-\x7F]' -and $raw -notmatch '\xC5\x91') {
        Remove-Item $oldSessions -Force -ErrorAction SilentlyContinue
        Write-Info "Cleaned stale session data (encoding fix)"
    }
}

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

    $template = Get-Content $templatePath -Raw | ConvertFrom-Json

    if (-not (Test-Path $Settings)) {
        # Create new settings from template
        $template.PSObject.Properties.Remove('_comment')
        $template.PSObject.Properties.Remove('_instructions')
        ConvertTo-SafeCommands $template
        Write-SettingsJson ($template | ConvertTo-Json -Depth 10)
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
        $template.PSObject.Properties.Remove('_comment')
        $template.PSObject.Properties.Remove('_instructions')
        ConvertTo-SafeCommands $template
        Write-SettingsJson ($template | ConvertTo-Json -Depth 10)
        Write-Ok "Created settings.json from template (previous file was empty/invalid)"
        return
    }

    if ($existing.hooks) {
        Write-Warn "Hooks already configured in settings.json -- not overwriting"
        Write-Warn "Compare with windows/settings-template.json to see what's new"

        # Still merge statusLine if it's missing
        if (-not $existing.statusLine -and $template.statusLine) {
            $backup = "$Settings.pre-monitor-statusline-backup"
            Copy-Item $Settings $backup -Force
            $existing | Add-Member -NotePropertyName "statusLine" -NotePropertyValue $template.statusLine -Force
        }

        # Convert existing commands to EncodedCommand (Unicode username fix)
        $needsFix = $false
        foreach ($eventProp in $existing.hooks.PSObject.Properties) {
            foreach ($group in $eventProp.Value) {
                foreach ($h in $group.hooks) {
                    if ($h.command -match '-File\s' -and $h.command -match '\.ps1') {
                        $needsFix = $true
                        break
                    }
                }
                if ($needsFix) { break }
            }
            if ($needsFix) { break }
        }

        if ($needsFix) {
            $backup = "$Settings.pre-unicode-fix-backup"
            Copy-Item $Settings $backup -Force
            ConvertTo-SafeCommands $existing
            Write-SettingsJson ($existing | ConvertTo-Json -Depth 10)
            Write-Ok "Converted hook commands to EncodedCommand (Unicode username fix)"
        } else {
            # Still re-save as UTF-8
            Write-SettingsJson ($existing | ConvertTo-Json -Depth 10)
        }
        return
    }

    # Merge hooks + statusLine into existing settings
    $backup = "$Settings.pre-monitor-backup"
    Copy-Item $Settings $backup -Force

    $existing | Add-Member -NotePropertyName "hooks" -NotePropertyValue $template.hooks -Force
    if ($template.statusLine) {
        $existing | Add-Member -NotePropertyName "statusLine" -NotePropertyValue $template.statusLine -Force
    }
    ConvertTo-SafeCommands $existing
    Write-SettingsJson ($existing | ConvertTo-Json -Depth 10)

    Write-Ok "Merged hooks + statusline into settings.json"
    Write-Ok "Backup saved to $backup"
}

# -- Install tray app -------------------------------------
function Install-App {
    Write-Info "Installing Claude Monitor tray app..."

    # Kill ALL existing tray app instances before installing
    try {
        # Kill old PowerShell-based tray apps
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'tray-app\.ps1' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        # Kill old compiled tray apps
        Get-Process "ClaudeMonitor" -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    } catch {}

    # Compile the C# tray app to a native .exe (no PowerShell encoding issues)
    $csSrc = Join-Path $ScriptDir "ClaudeMonitorTray.cs"
    $exeDst = Join-Path $ClaudeDir "ClaudeMonitor.exe"

    if (-not (Test-Path $csSrc)) {
        Write-Warn "ClaudeMonitorTray.cs not found -- skipping tray app"
        return
    }

    $cscDir = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $csc = Join-Path $cscDir "csc.exe"

    if (-not (Test-Path $csc)) {
        Write-Warn "C# compiler not found at $csc -- skipping tray app"
        Write-Warn "Install .NET Framework Developer Pack to enable the tray app"
        return
    }

    Write-Info "Compiling tray app..."

    # Copy source to temp path without Unicode chars (csc.exe + PS splatting
    # can fail when the source path contains chars like ő)
    $tmpCs = Join-Path $env:TEMP "ClaudeMonitorTray_build.cs"
    Copy-Item $csSrc $tmpCs -Force

    $refs = @(
        "/r:System.Windows.Forms.dll",
        "/r:System.Drawing.dll",
        "/r:System.Web.Extensions.dll"
    )
    $compileArgs = @("/nologo", "/target:winexe", "/optimize+", "/out:$exeDst") + $refs + @($tmpCs)

    # Temporarily lower error preference so csc warnings don't abort
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $result = & $csc @compileArgs 2>&1
    $compileExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    Remove-Item $tmpCs -Force -ErrorAction SilentlyContinue

    if ($compileExit -ne 0) {
        Write-Err "Compilation failed:"
        $result | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        # Fall back to PowerShell version
        $psSrc = Join-Path $ScriptDir "tray-app.ps1"
        if (Test-Path $psSrc) {
            Copy-Item $psSrc (Join-Path $ClaudeDir "tray-app.ps1") -Force
            Write-Warn "Falling back to PowerShell tray app"
        }
        return
    }

    Write-Ok "Compiled ClaudeMonitor.exe"

    # Create a launcher batch file for easy startup / login
    $launcher = Join-Path $ClaudeDir "ClaudeMonitor.bat"
    @"
@echo off
start "" "$exeDst"
"@ | Set-Content $launcher

    Write-Ok "Launcher created: $launcher"

    # Launch the compiled app
    Start-Process -FilePath $exeDst -WindowStyle Hidden
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
