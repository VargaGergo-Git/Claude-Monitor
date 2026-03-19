# Session Start -- session tracking for Claude Monitor
# Hook type: SessionStart
# PowerShell version for native Windows Claude Code

$ErrorActionPreference = 'SilentlyContinue'

# Only read stdin if it's piped -- avoids blocking when Claude Code
# doesn't pipe data to this hook event
$InputData = ""
if ([Console]::IsInputRedirected) {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $InputData = $reader.ReadToEnd()
}

$json = $InputData | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit 0 }

$Dir = $json.cwd
$SessionId = $json.session_id
if (-not $Dir) { exit 0 }

$claudeDir = Join-Path $env:USERPROFILE ".claude"

# Reset session-scoped state
Set-Content -Path (Join-Path $claudeDir ".files_read") -Value "" -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $claudeDir ".active_agents") -Value "0" -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $claudeDir ".agent_activity") -Value "" -ErrorAction SilentlyContinue

# -- Session tracking --------------------------------------
$sessionsFile = Join-Path $claudeDir ".sessions.json"
if (-not (Test-Path $sessionsFile)) {
    Set-Content -Path $sessionsFile -Value "[]" -ErrorAction SilentlyContinue
}

if ($SessionId) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $proj = Split-Path $Dir -Leaf
    $branch = ""
    try {
        Push-Location $Dir
        $branch = git branch --show-current 2>$null
        Pop-Location
    } catch { try { Pop-Location } catch {} }

    try {
        $sessions = Get-Content $sessionsFile -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if (-not $sessions) { $sessions = @() }

        # Remove stale (>6h) and same-dir sessions
        $sessions = @($sessions | Where-Object {
            $_.id -ne $SessionId -and $_.dir -ne $Dir -and ($now - $_.lastActive) -lt 21600
        })

        $sessions += [PSCustomObject]@{
            id = $SessionId
            project = $proj
            branch = $branch
            dir = $Dir
            started = $now
            lastActive = $now
            status = "active"
            agents = 0
        }

        ConvertTo-Json @($sessions) -Depth 3 | Set-Content $sessionsFile -ErrorAction SilentlyContinue
    } catch {}
}

# -- Build output ------------------------------------------
$msg = ""

# Handoff notes
$handoff = Join-Path $Dir ".claude\handoff.md"
if (Test-Path $handoff) {
    $msg = "Handoff notes from last session -- read .claude/handoff.md to pick up where you left off."
}

# Git status
try {
    Push-Location $Dir
    $branch = git branch --show-current 2>$null
    $dirty = (git status --porcelain 2>$null | Measure-Object).Count
    Pop-Location

    if ($branch) {
        $gitMsg = "Branch: $branch"
        if ($dirty -gt 0) { $gitMsg += " -- $dirty uncommitted changes" }
        $msg = if ($msg) { "$msg`n$gitMsg" } else { $gitMsg }
    }
} catch { try { Pop-Location } catch {} }

if ($msg) {
    @{ systemMessage = $msg } | ConvertTo-Json -Compress
}

exit 0
