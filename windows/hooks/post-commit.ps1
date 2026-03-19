# Post-commit celebration — notify what was shipped
# Hook type: PostToolUse (matcher: Bash)
# PowerShell version for native Windows Claude Code

$Input = $input | Out-String
$json = $Input | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$cmd = $json.tool_input.command
if (-not $cmd -or $cmd -notmatch "git commit") { exit }

$Dir = $json.cwd
if (-not $Dir) { exit }

try {
    Push-Location $Dir
    $subject = git log -1 --pretty=format:"%s" 2>$null
    $files = (git diff-tree --no-commit-id --name-only -r HEAD 2>$null | Measure-Object).Count
    $branch = git branch --show-current 2>$null
    $proj = Split-Path $Dir -Leaf
    Pop-Location

    if ($subject) {
        $msg = "Shipped: `"$subject`" — $files files on $branch"

        # Toast notification
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipTitle = $proj
        $notify.BalloonTipText = $msg
        $notify.Visible = $true
        $notify.ShowBalloonTip(5000)
        Start-Sleep -Milliseconds 100
        $notify.Dispose()

        @{ systemMessage = $msg } | ConvertTo-Json -Compress
    }
} catch { Pop-Location }
