# Claude Monitor — Windows System Tray App
# Monitors Claude Code sessions and shows status in the system tray
# Requires: Windows 10+, PowerShell 5.1+
# Usage: powershell -ExecutionPolicy Bypass -File tray-app.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$script:Sessions = @()
$script:NameCache = @{}
$script:PrevStates = @{}
$script:CtxWarned = [System.Collections.Generic.HashSet[string]]::new()

# ── Settings (persisted in registry) ────────────────────────
$script:RegPath = "HKCU:\Software\ClaudeMonitor"
if (-not (Test-Path $script:RegPath)) { New-Item -Path $script:RegPath -Force | Out-Null }

function Get-Setting($Name, $Default) {
    try { (Get-ItemProperty -Path $script:RegPath -Name $Name -ErrorAction Stop).$Name }
    catch { $Default }
}
function Set-Setting($Name, $Value) {
    Set-ItemProperty -Path $script:RegPath -Name $Name -Value $Value
}

$script:NotifyWaiting = [bool](Get-Setting "NotifyWaiting" 1)
$script:NotifyContext = [bool](Get-Setting "NotifyContext" 1)
$script:NotifySound = [bool](Get-Setting "NotifySound" 1)

# ── Toast Notifications ─────────────────────────────────────
function Show-Notification($Title, $Body) {
    $script:TrayIcon.BalloonTipTitle = $Title
    $script:TrayIcon.BalloonTipText = $Body
    $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $script:TrayIcon.ShowBalloonTip(5000)
}

# ── Name Cache ──────────────────────────────────────────────
function Load-NameCache {
    $path = Join-Path $script:ClaudeDir ".session_names"
    if (Test-Path $path) {
        Get-Content $path | ForEach-Object {
            $parts = $_ -split '\|', 2
            if ($parts.Count -eq 2) {
                $script:NameCache[$parts[0]] = $parts[1]
            }
        }
    }
}

# ── Cleanup stale files ────────────────────────────────────
function Cleanup-StaleFiles {
    $prefixes = @(".ctx_", ".state_", ".ctxlog_", ".tty_map_", ".tty_resolved_", ".activity_", ".files_", ".ctx_pct_")
    $cutoff = (Get-Date).AddHours(-24)
    Get-ChildItem -Path $script:ClaudeDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.Name
        $match = $false
        foreach ($prefix in $prefixes) {
            if ($name.StartsWith($prefix)) { $match = $true; break }
        }
        if ($match -and $_.LastWriteTime -lt $cutoff) {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ── Scan for Claude sessions ───────────────────────────────
function Scan-Sessions {
    $results = @()

    # Find claude processes — works for both native and WSL
    $claudeProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^(claude|node)\.exe$" -and $_.CommandLine -match "claude" } |
        Select-Object ProcessId, CommandLine, CreationDate

    # Also check WSL processes
    $wslSessions = @()
    try {
        $wslOutput = wsl ps -eo pid,args 2>$null | Where-Object { $_ -match "claude" -and $_ -notmatch "grep" }
        foreach ($line in $wslOutput) {
            if ($line -match '^\s*(\d+)\s+(.+)$') {
                $wslSessions += @{ Pid = $Matches[1]; Args = $Matches[2] }
            }
        }
    } catch {}

    # Check state files for all known session IDs
    $stateFiles = Get-ChildItem -Path $script:ClaudeDir -Filter ".state_*" -File -ErrorAction SilentlyContinue
    foreach ($stateFile in $stateFiles) {
        $sid = $stateFile.Name -replace '^\.state_', ''
        if (-not $sid) { continue }

        $state = (Get-Content $stateFile.FullName -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]
        $state = if ($state) { $state.Trim() } else { "" }

        # Get context info
        $ctx = ""
        $ctxFile = Join-Path $script:ClaudeDir ".ctx_$sid"
        if (Test-Path $ctxFile) {
            $ctx = (Get-Content $ctxFile -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]
            if ($ctx) { $ctx = $ctx.Substring(0, [Math]::Min($ctx.Length, 40)) }
        }

        # Get context percentage
        $ctxPct = 0
        $ctxPctFile = Join-Path $script:ClaudeDir ".ctx_pct_$sid"
        if (Test-Path $ctxPctFile) {
            $pctStr = (Get-Content $ctxPctFile -ErrorAction SilentlyContinue | Select-Object -First 1) -as [string]
            if ($pctStr) { $ctxPct = [int]($pctStr.Split('.')[0]) }
        }

        # Get project info from sessions.json
        $project = "Unknown"
        $branch = ""
        $dir = ""
        $modified = 0
        $lastCommit = ""

        $sessionsFile = Join-Path $script:ClaudeDir ".sessions.json"
        if (Test-Path $sessionsFile) {
            try {
                $sessionsJson = Get-Content $sessionsFile -Raw | ConvertFrom-Json
                $sessionInfo = $sessionsJson | Where-Object { $_.id -eq $sid } | Select-Object -First 1
                if ($sessionInfo) {
                    $project = $sessionInfo.project
                    $branch = $sessionInfo.branch
                    $dir = $sessionInfo.dir

                    # Calculate duration
                    $started = [DateTimeOffset]::FromUnixTimeSeconds($sessionInfo.started).LocalDateTime
                    $elapsed = (Get-Date) - $started
                }
            } catch {}
        }

        # Try to get git info if we have a dir
        if ($dir) {
            try {
                $gitDir = $dir
                # Handle WSL paths
                if ($dir -match '^/') {
                    $wslDistro = (wsl -l -q 2>$null | Select-Object -First 1) -as [string]
                    if ($wslDistro) {
                        $gitDir = "\\wsl$\$($wslDistro.Trim())$($dir -replace '/', '\')"
                    }
                }

                if (Test-Path $gitDir -ErrorAction SilentlyContinue) {
                    $modified = (git -C $gitDir status --porcelain 2>$null | Measure-Object).Count
                    $lastCommit = git -C $gitDir log -1 --format='%s' 2>$null | Select-Object -First 1
                    if ($lastCommit -and $lastCommit.Length -gt 45) {
                        $lastCommit = $lastCommit.Substring(0, 45)
                    }
                }
            } catch {}
        }

        # Format duration
        $duration = ""
        if ($elapsed) {
            if ($elapsed.TotalMinutes -lt 1) { $duration = "$([int]$elapsed.TotalSeconds)s" }
            elseif ($elapsed.TotalHours -lt 1) { $duration = "$([int]$elapsed.TotalMinutes)m" }
            else {
                $h = [int]$elapsed.TotalHours
                $m = [int]($elapsed.TotalMinutes % 60)
                $duration = if ($m -gt 0) { "${h}h${m}m" } else { "${h}h" }
            }
        }

        $name = if ($script:NameCache.ContainsKey($sid)) { $script:NameCache[$sid] } else { "" }

        $results += [PSCustomObject]@{
            Sid = $sid
            Project = $project
            Branch = $branch
            Dir = $dir
            Duration = $duration
            State = $state
            Context = $ctx
            ContextPct = $ctxPct
            ModifiedFiles = $modified
            LastCommit = $lastCommit
            Name = $name
        }
    }

    $script:Sessions = $results
    Check-Notifications
}

# ── Check notifications ────────────────────────────────────
function Check-Notifications {
    foreach ($session in $script:Sessions) {
        $sid = $session.Sid
        $prev = if ($script:PrevStates.ContainsKey($sid)) { $script:PrevStates[$sid] } else { "" }
        $curr = $session.State

        # Notify: active -> waiting
        if ($script:NotifyWaiting -and $prev -eq "active" -and $curr -eq "waiting") {
            $name = if ($session.Name) { $session.Name } else { $session.Project }
            Show-Notification $name "Ready for your input"
        }

        # Warn: context crossed 80%
        if ($script:NotifyContext -and $session.ContextPct -ge 80 -and -not $script:CtxWarned.Contains($sid)) {
            $script:CtxWarned.Add($sid) | Out-Null
            $name = if ($session.Name) { $session.Name } else { $session.Project }
            Show-Notification "$name — Context $($session.ContextPct)%" "Consider running /compact to free up space"
        }

        $script:PrevStates[$sid] = $curr
    }
}

# ── Build context menu ─────────────────────────────────────
function Build-Menu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 40)
    $menu.ForeColor = [System.Drawing.Color]::White
    $menu.ShowImageMargin = $false

    $n = $script:Sessions.Count
    $waitingCount = ($script:Sessions | Where-Object { $_.State -eq "waiting" }).Count

    # Update tray icon tooltip
    $tooltip = "Claude Monitor: $n session$(if ($n -ne 1) {'s'})"
    if ($waitingCount -gt 0) { $tooltip += " ($waitingCount waiting)" }
    $script:TrayIcon.Text = $tooltip

    if ($n -eq 0) {
        $item = $menu.Items.Add("No active sessions")
        $item.Enabled = $false
        $item.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
    } else {
        # Group by project
        $groups = $script:Sessions | Group-Object -Property Dir

        foreach ($group in $groups) {
            $first = $group.Group[0]

            # Project header
            $header = $menu.Items.Add("$($first.Project)  $($first.Branch)")
            $header.Enabled = $false
            $header.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
            $header.ForeColor = [System.Drawing.Color]::White

            # Branch warning
            if ($group.Count -gt 1) {
                $warn = $menu.Items.Add("  ⚠ $($group.Count) sessions sharing one branch")
                $warn.Enabled = $false
                $warn.ForeColor = [System.Drawing.Color]::FromArgb(255, 190, 70)
            }

            # Git info
            if ($first.ModifiedFiles -gt 0 -or $first.LastCommit) {
                $info = ""
                if ($first.ModifiedFiles -gt 0) { $info = "  $($first.ModifiedFiles) changed" }
                if ($first.LastCommit) {
                    $info += if ($info) { " · $($first.LastCommit)" } else { "  $($first.LastCommit)" }
                }
                $gitItem = $menu.Items.Add($info)
                $gitItem.Enabled = $false
                $gitItem.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
                $gitItem.Font = New-Object System.Drawing.Font("Cascadia Mono", 8.5)
            }

            $menu.Items.Add("-") | Out-Null

            foreach ($session in $group.Group) {
                $displayName = if ($session.Name) { $session.Name }
                    elseif ($session.State -eq "waiting") { "Waiting for input" }
                    else { "Session" }

                # State indicator
                $dot = switch ($session.State) {
                    "active"  { "● " }
                    "waiting" { "● " }
                    default   { "○ " }
                }

                $label = "  $dot$displayName  $($session.Duration)"
                if ($session.ContextPct -gt 0) {
                    $label += "  ctx $($session.ContextPct)%"
                }

                $sessionItem = $menu.Items.Add($label)

                # Color based on state
                $sessionItem.ForeColor = switch ($session.State) {
                    "active"  { [System.Drawing.Color]::FromArgb(100, 220, 140) }
                    "waiting" { [System.Drawing.Color]::FromArgb(240, 190, 60) }
                    default   { [System.Drawing.Color]::FromArgb(140, 140, 140) }
                }
                $sessionItem.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)

                # Context line
                $ctxText = if ($session.Context) { $session.Context }
                    elseif ($session.State -eq "waiting") { "Waiting for your input" }
                    else { "Starting up..." }

                $ctxItem = $menu.Items.Add("      $ctxText")
                $ctxItem.Enabled = $false
                $ctxItem.ForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
                $ctxItem.Font = New-Object System.Drawing.Font("Segoe UI", 9)
            }

            $menu.Items.Add("-") | Out-Null
        }
    }

    # ── Usage section ──────────────────────────────────────
    $usageCache = Join-Path $script:ClaudeDir ".usage_cache.json"
    if (Test-Path $usageCache) {
        try {
            $usage = Get-Content $usageCache -Raw | ConvertFrom-Json

            $sessPct = [int]($usage.five_hour.utilization)
            $weekPct = [int]($usage.seven_day.utilization)

            $sessBar = Make-Bar $sessPct 16
            $weekBar = Make-Bar $weekPct 16

            $sessItem = $menu.Items.Add("  Session $sessBar $sessPct%")
            $sessItem.Enabled = $false
            $sessItem.Font = New-Object System.Drawing.Font("Cascadia Mono", 9)
            $sessItem.ForeColor = Get-UsageColor $sessPct

            $weekItem = $menu.Items.Add("  Weekly  $weekBar $weekPct%")
            $weekItem.Enabled = $false
            $weekItem.Font = New-Object System.Drawing.Font("Cascadia Mono", 9)
            $weekItem.ForeColor = Get-UsageColor $weekPct
        } catch {}
    }

    $menu.Items.Add("-") | Out-Null

    # ── Settings ───────────────────────────────────────────
    $refreshItem = $menu.Items.Add("Refresh")
    $refreshItem.Add_Click({ Scan-Sessions; Build-Menu })

    $settingsMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Settings")
    $settingsMenu.ForeColor = [System.Drawing.Color]::White

    $waitCheck = New-Object System.Windows.Forms.ToolStripMenuItem("Waiting Alerts")
    $waitCheck.Checked = $script:NotifyWaiting
    $waitCheck.Add_Click({
        $script:NotifyWaiting = -not $script:NotifyWaiting
        Set-Setting "NotifyWaiting" ([int]$script:NotifyWaiting)
        $this.Checked = $script:NotifyWaiting
    })
    $settingsMenu.DropDownItems.Add($waitCheck) | Out-Null

    $ctxCheck = New-Object System.Windows.Forms.ToolStripMenuItem("Context Warnings")
    $ctxCheck.Checked = $script:NotifyContext
    $ctxCheck.Add_Click({
        $script:NotifyContext = -not $script:NotifyContext
        Set-Setting "NotifyContext" ([int]$script:NotifyContext)
        $this.Checked = $script:NotifyContext
    })
    $settingsMenu.DropDownItems.Add($ctxCheck) | Out-Null

    # Startup toggle
    $startupPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ClaudeMonitor.lnk"
    $startupCheck = New-Object System.Windows.Forms.ToolStripMenuItem("Launch at Login")
    $startupCheck.Checked = Test-Path $startupPath
    $startupCheck.Add_Click({
        $lnkPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ClaudeMonitor.lnk"
        if (Test-Path $lnkPath) {
            Remove-Item $lnkPath -Force
            $this.Checked = $false
        } else {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($lnkPath)
            $shortcut.TargetPath = "powershell.exe"
            $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\tray-app.ps1`""
            $shortcut.WindowStyle = 7  # Minimized
            $shortcut.Save()
            $this.Checked = $true
        }
    })
    $settingsMenu.DropDownItems.Add($startupCheck) | Out-Null

    $menu.Items.Add($settingsMenu) | Out-Null

    $quitItem = $menu.Items.Add("Quit")
    $quitItem.Add_Click({
        $script:TrayIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

    $script:TrayIcon.ContextMenuStrip = $menu
}

# ── Helpers ─────────────────────────────────────────────────
function Make-Bar($pct, $width) {
    $filled = [int]($pct * $width / 100)
    if ($filled -gt $width) { $filled = $width }
    $bar = ("█" * $filled) + ("░" * ($width - $filled))
    return $bar
}

function Get-UsageColor($pct) {
    if ($pct -ge 80) { return [System.Drawing.Color]::FromArgb(210, 70, 60) }
    if ($pct -ge 50) { return [System.Drawing.Color]::FromArgb(200, 160, 40) }
    return [System.Drawing.Color]::FromArgb(80, 180, 110)
}

# ── Create tray icon ───────────────────────────────────────
# Draw a simple diamond icon
$bitmap = New-Object System.Drawing.Bitmap(16, 16)
$g = [System.Drawing.Graphics]::FromImage($bitmap)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$points = @(
    [System.Drawing.Point]::new(8, 1),
    [System.Drawing.Point]::new(15, 8),
    [System.Drawing.Point]::new(8, 15),
    [System.Drawing.Point]::new(1, 8)
)
$g.FillPolygon([System.Drawing.Brushes]::DodgerBlue, $points)
$g.Dispose()
$icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())

$script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayIcon.Icon = $icon
$script:TrayIcon.Text = "Claude Monitor"
$script:TrayIcon.Visible = $true

# Click to open menu
$script:TrayIcon.Add_Click({
    if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Build-Menu
        # Show context menu at cursor
        $mi = $script:TrayIcon.GetType().GetMethod("ShowContextMenu",
            [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
        if ($mi) { $mi.Invoke($script:TrayIcon, $null) }
    }
})

# ── Initial scan and timers ─────────────────────────────────
Cleanup-StaleFiles
Load-NameCache
Scan-Sessions
Build-Menu

# Scan every 10 seconds
$scanTimer = New-Object System.Windows.Forms.Timer
$scanTimer.Interval = 10000
$scanTimer.Add_Tick({
    Scan-Sessions
    Build-Menu
})
$scanTimer.Start()

# Run the app
[System.Windows.Forms.Application]::Run()

# Cleanup
$script:TrayIcon.Visible = $false
$script:TrayIcon.Dispose()
$bitmap.Dispose()
