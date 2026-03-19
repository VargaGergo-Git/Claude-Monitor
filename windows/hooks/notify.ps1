# Notification hook -- Windows toast notifications
# Hook type: Notification
# PowerShell version for native Windows Claude Code

$Input = $input | Out-String
$json = $Input | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$Msg = if ($json.message) { $json.message } else { "Task completed" }
$Type = if ($json.type) { $json.type } else { "" }
$Dir = if ($json.cwd) { $json.cwd } else { "" }
$Proj = if ($Dir) { Split-Path $Dir -Leaf } else { "Claude Code" }

$Title = switch ($Type) {
    "permission_prompt" { "$Proj -- Needs Approval" }
    "idle_prompt"       { "$Proj -- Ready" }
    "auth_success"      { "$Proj -- Authenticated" }
    default             { $Proj }
}

# Truncate long messages
if ($Msg.Length -gt 100) { $Msg = $Msg.Substring(0, 100) }

# Windows toast notification
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.BalloonTipTitle = $Title
$notify.BalloonTipText = $Msg
$notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
$notify.Visible = $true
$notify.ShowBalloonTip(5000)
Start-Sleep -Milliseconds 100
$notify.Dispose()
