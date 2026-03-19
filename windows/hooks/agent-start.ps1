# Track active agents -- increment count + log description
# Hook type: SubagentStart
# PowerShell version for native Windows Claude Code

$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$InputData = $reader.ReadToEnd()
$json = $InputData | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$claudeDir = Join-Path $env:USERPROFILE ".claude"
$counterFile = Join-Path $claudeDir ".active_agents"
$agentsFile = Join-Path $claudeDir ".agent_activity"
$sessionsFile = Join-Path $claudeDir ".sessions.json"

# Increment count
$current = 0
if (Test-Path $counterFile) { $current = [int](Get-Content $counterFile -ErrorAction SilentlyContinue) }
$newCount = $current + 1
Set-Content -Path $counterFile -Value $newCount -NoNewline

# Capture description
$desc = $json.agent_name
if (-not $desc) { $desc = $json.tool_input.description }
if (-not $desc) { $desc = "working" }

$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Add-Content -Path $agentsFile -Value "$ts|$desc" -ErrorAction SilentlyContinue

# Update session
$sessionId = $json.session_id
if ($sessionId -and (Test-Path $sessionsFile)) {
    try {
        $sessions = Get-Content $sessionsFile -Raw | ConvertFrom-Json
        $sessions | ForEach-Object {
            if ($_.id -eq $sessionId) { $_.agents = $newCount; $_.status = "active" }
        }
        [System.IO.File]::WriteAllText($sessionsFile, (ConvertTo-Json @($sessions) -Depth 3), (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}
