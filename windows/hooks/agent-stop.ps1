# Track active agents -- decrement count
# Hook type: SubagentStop
# PowerShell version for native Windows Claude Code

$Input = $input | Out-String
$json = $Input | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$claudeDir = Join-Path $env:USERPROFILE ".claude"
$counterFile = Join-Path $claudeDir ".active_agents"
$agentsFile = Join-Path $claudeDir ".agent_activity"
$sessionsFile = Join-Path $claudeDir ".sessions.json"

# Decrement count
$current = 1
if (Test-Path $counterFile) { $current = [int](Get-Content $counterFile -ErrorAction SilentlyContinue) }
$newCount = [Math]::Max(0, $current - 1)
Set-Content -Path $counterFile -Value $newCount -NoNewline

# Clean activity log
if (Test-Path $agentsFile) {
    if ($newCount -eq 0) {
        Set-Content -Path $agentsFile -Value "" -ErrorAction SilentlyContinue
    } else {
        $lines = Get-Content $agentsFile -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt $newCount) {
            $lines | Select-Object -Last $newCount | Set-Content $agentsFile
        }
    }
}

# Update session
$sessionId = $json.session_id
if ($sessionId -and (Test-Path $sessionsFile)) {
    try {
        $sessions = Get-Content $sessionsFile -Raw | ConvertFrom-Json
        $sessions | ForEach-Object {
            if ($_.id -eq $sessionId) { $_.agents = $newCount }
        }
        $sessions | ConvertTo-Json -AsArray | Set-Content $sessionsFile
    } catch {}
}
