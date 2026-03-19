# Claude Monitor -- Windows System Tray App
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

# -- Settings (persisted in registry) ------------------------
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
$script:EnableHaiku = [bool](Get-Setting "EnableHaiku" 1)

# Haiku API state
$script:CachedToken = $null
$script:PendingNames = [System.Collections.Generic.HashSet[string]]::new()
$script:SmartCtxCache = @{}
$script:LastCtxHash = @{}
$script:PendingCtx = [System.Collections.Generic.HashSet[string]]::new()
$script:HaikuCallCount = [int](Get-Setting "HaikuCalls" 0)
$script:HaikuTokensUsed = [int](Get-Setting "HaikuTokens" 0)

# -- Windows Credential Manager (P/Invoke) --------------------
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class WinCred {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int reserved, out IntPtr cred);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type;
        public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount;
        public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    public static string GetPassword(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
        string pass = null;
        if (cred.CredentialBlobSize > 0) {
            // Try UTF-16 first (standard Windows credential encoding)
            pass = Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
            // If it doesn't look like JSON, try UTF-8 (Node.js apps often store UTF-8)
            if (pass == null || !pass.TrimStart().StartsWith("{")) {
                byte[] bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
                pass = System.Text.Encoding.UTF8.GetString(bytes);
            }
        }
        CredFree(ptr);
        return pass;
    }
}
"@ -ErrorAction SilentlyContinue
} catch {}

# -- Toast Notifications -------------------------------------
function Show-Notification($Title, $Body) {
    $script:TrayIcon.BalloonTipTitle = $Title
    $script:TrayIcon.BalloonTipText = $Body
    $script:TrayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $script:TrayIcon.ShowBalloonTip(5000)
}

# -- Name Cache ----------------------------------------------
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

function Save-NameToCache($sid, $name) {
    $script:NameCache[$sid] = $name
    $path = Join-Path $script:ClaudeDir ".session_names"
    Add-Content -Path $path -Value "$sid|$name" -ErrorAction SilentlyContinue
}

# -- Haiku API ------------------------------------------------
function Get-OAuthToken {
    if ($script:CachedToken) { return $script:CachedToken }
    try {
        $credJson = [WinCred]::GetPassword("Claude Code-credentials")
        if ($credJson) {
            $credObj = $credJson | ConvertFrom-Json
            $token = $credObj.claudeAiOauth.accessToken
            if ($token) { $script:CachedToken = $token; return $token }
        }
    } catch {}
    return $null
}

function Invoke-Haiku($prompt, $maxTokens) {
    $token = Get-OAuthToken
    if (-not $token) { return $null }

    try {
        $body = @{
            model = "claude-haiku-4-5-20251001"
            max_tokens = $maxTokens
            messages = @(@{ role = "user"; content = $prompt })
        } | ConvertTo-Json -Depth 3

        $headers = @{
            "Authorization"    = "Bearer $token"
            "anthropic-beta"   = "oauth-2025-04-20"
            "anthropic-version" = "2023-06-01"
            "content-type"     = "application/json"
        }

        $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
            -Method Post -Headers $headers -Body $body -TimeoutSec 8

        if ($resp.content -and $resp.content[0].text) {
            # Track usage
            if ($resp.usage) {
                $script:HaikuCallCount++
                $script:HaikuTokensUsed += ($resp.usage.input_tokens + $resp.usage.output_tokens)
                Set-Setting "HaikuCalls" $script:HaikuCallCount
                Set-Setting "HaikuTokens" $script:HaikuTokensUsed
            }
            return $resp.content[0].text
        }
    } catch {}
    return $null
}

function Resolve-Names {
    if (-not $script:EnableHaiku) { return }
    foreach ($session in $script:Sessions) {
        $sid = $session.Sid
        if ($session.Name -or -not $sid) { continue }
        if ($script:PendingNames.Contains($sid)) { continue }
        $script:PendingNames.Add($sid) | Out-Null

        # Find session JSONL
        $projectHash = $session.Dir -replace '[/\\]', '-' -replace ' ', '-'
        $jsonlPath = Join-Path $script:ClaudeDir "projects\$projectHash\$sid.jsonl"
        if (-not (Test-Path $jsonlPath)) {
            $script:PendingNames.Remove($sid) | Out-Null
            continue
        }

        $rawMsg = ""
        Get-Content $jsonlPath -TotalCount 200 | ForEach-Object {
            if ($rawMsg) { return }
            try {
                $obj = $_ | ConvertFrom-Json
                if ($obj.type -eq "user" -and $obj.message.content -and
                    -not $obj.message.content.StartsWith("<") -and $obj.message.content.Length -gt 5) {
                    $rawMsg = $obj.message.content.Substring(0, [Math]::Min($obj.message.content.Length, 200))
                }
            } catch {}
        }

        if (-not $rawMsg) {
            $script:PendingNames.Remove($sid) | Out-Null
            continue
        }

        $name = Invoke-Haiku "Give a 2-5 word title for this coding task. Reply ONLY the title. Task: $rawMsg" 15
        if (-not $name) {
            $name = ($rawMsg -split "`n")[0]
            if ($name.Length -gt 35) { $name = $name.Substring(0, 35) }
        }
        Save-NameToCache $sid $name
        $script:PendingNames.Remove($sid) | Out-Null
    }
}

function Resolve-SmartContexts {
    if (-not $script:EnableHaiku) { return }
    foreach ($session in $script:Sessions) {
        $sid = $session.Sid
        if (-not $sid) { continue }
        if ($script:PendingCtx.Contains($sid)) { continue }

        $logPath = Join-Path $script:ClaudeDir ".ctxlog_$sid"
        if (-not (Test-Path $logPath)) { continue }
        $logData = (Get-Content $logPath -Raw -ErrorAction SilentlyContinue)
        if (-not $logData -or -not $logData.Trim()) { continue }

        $hash = $logData.GetHashCode().ToString()
        if ($script:LastCtxHash.ContainsKey($sid) -and $script:LastCtxHash[$sid] -eq $hash) { continue }
        $script:LastCtxHash[$sid] = $hash
        $script:PendingCtx.Add($sid) | Out-Null

        $actions = ($logData -split "`n" | Select-Object -Last 6) -join ", "

        # Git diff for richer context
        $diffStat = ""
        if ($session.Dir) {
            try {
                Push-Location $session.Dir
                $diff = git diff --stat HEAD 2>$null
                if ($diff) { $diffStat = ", Git changes: $(($diff -split "`n" | Select-Object -Last 1).Trim())" }
                Pop-Location
            } catch { Pop-Location }
        }

        $summary = Invoke-Haiku "What is this coding session doing RIGHT NOW? Recent actions: $actions$diffStat. Reply in 5-10 words, present tense, specific. No quotes." 25
        if ($summary) { $script:SmartCtxCache[$sid] = $summary }
        $script:PendingCtx.Remove($sid) | Out-Null
    }
}

# -- Cleanup stale files ------------------------------------
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

# -- Scan for Claude sessions -------------------------------
function Scan-Sessions {
    $results = @()

    # Find claude processes -- works for both native and WSL
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

        $smartCtx = if ($script:SmartCtxCache.ContainsKey($sid)) { $script:SmartCtxCache[$sid] } else { "" }

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
            SmartContext = $smartCtx
        }
    }

    $script:Sessions = $results
    Resolve-Names
    Check-Notifications
}

# -- Check notifications ------------------------------------
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
            Show-Notification "$name -- Context $($session.ContextPct)%" "Consider running /compact to free up space"
        }

        $script:PrevStates[$sid] = $curr
    }
}

# -- Build context menu -------------------------------------
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
                $warn = $menu.Items.Add("  ! $($group.Count) sessions sharing one branch")
                $warn.Enabled = $false
                $warn.ForeColor = [System.Drawing.Color]::FromArgb(255, 190, 70)
            }

            # Git info
            if ($first.ModifiedFiles -gt 0 -or $first.LastCommit) {
                $info = ""
                if ($first.ModifiedFiles -gt 0) { $info = "  $($first.ModifiedFiles) changed" }
                if ($first.LastCommit) {
                    $info += if ($info) { " . $($first.LastCommit)" } else { "  $($first.LastCommit)" }
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
                    "active"  { "* " }
                    "waiting" { "* " }
                    default   { "o " }
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

                # Context line -- prefer Haiku smart context, then raw context
                $ctxText = if ($session.SmartContext) { $session.SmartContext }
                    elseif ($session.Context) { $session.Context }
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

    # -- Usage section --------------------------------------
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

            # Haiku overhead
            if ($script:EnableHaiku -and $script:HaikuCallCount -gt 0) {
                $haikuInfo = $menu.Items.Add("  Monitor: $($script:HaikuCallCount) Haiku calls, ~$($script:HaikuTokensUsed) tok")
                $haikuInfo.Enabled = $false
                $haikuInfo.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 120)
                $haikuInfo.Font = New-Object System.Drawing.Font("Segoe UI", 8)
            }
        } catch {}
    }

    $menu.Items.Add("-") | Out-Null

    # -- Settings -------------------------------------------
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

    $haikuCheck = New-Object System.Windows.Forms.ToolStripMenuItem("AI Session Names")
    $haikuCheck.Checked = $script:EnableHaiku
    $haikuCheck.Add_Click({
        $script:EnableHaiku = -not $script:EnableHaiku
        Set-Setting "EnableHaiku" ([int]$script:EnableHaiku)
        $this.Checked = $script:EnableHaiku
    })
    $settingsMenu.DropDownItems.Add($haikuCheck) | Out-Null

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

# -- Helpers -------------------------------------------------
function Make-Bar($pct, $width) {
    $filled = [int]($pct * $width / 100)
    if ($filled -gt $width) { $filled = $width }
    $bar = ("#" * $filled) + ("-" * ($width - $filled))
    return $bar
}

function Get-UsageColor($pct) {
    if ($pct -ge 80) { return [System.Drawing.Color]::FromArgb(210, 70, 60) }
    if ($pct -ge 50) { return [System.Drawing.Color]::FromArgb(200, 160, 40) }
    return [System.Drawing.Color]::FromArgb(80, 180, 110)
}

# -- Create tray icon ---------------------------------------
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

# -- Initial scan and timers ---------------------------------
# Ensure ~/.claude/ exists (works even before first Claude Code session)
New-Item -ItemType Directory -Path $script:ClaudeDir -Force -ErrorAction SilentlyContinue | Out-Null
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

# Haiku smart context every 45 seconds
$haikuTimer = New-Object System.Windows.Forms.Timer
$haikuTimer.Interval = 45000
$haikuTimer.Add_Tick({
    if ($script:EnableHaiku) {
        Resolve-SmartContexts
        Build-Menu
    }
})
$haikuTimer.Start()

# Run the app
[System.Windows.Forms.Application]::Run()

# Cleanup
$script:TrayIcon.Visible = $false
$script:TrayIcon.Dispose()
$bitmap.Dispose()
