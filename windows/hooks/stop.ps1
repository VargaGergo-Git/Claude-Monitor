# Stop hook -- mark session as waiting + auto-handoff
# Hook type: Stop
# PowerShell version for native Windows Claude Code

$ErrorActionPreference = 'SilentlyContinue'

$InputData = [Console]::In.ReadToEnd()
$json = $InputData | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$Dir = $json.cwd
$SessionId = $json.session_id
$claudeDir = Join-Path $env:USERPROFILE ".claude"

# -- Session tracking --------------------------------------
$sessionsFile = Join-Path $claudeDir ".sessions.json"
if ($SessionId -and (Test-Path $sessionsFile)) {
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $sessions = Get-Content $sessionsFile -Raw | ConvertFrom-Json
        $sessions | ForEach-Object {
            if ($_.id -eq $SessionId) { $_.lastActive = $now }
        }
        ConvertTo-Json @($sessions) -Depth 3 | Set-Content $sessionsFile
    } catch {}
}

# -- Mark session as WAITING -------------------------------
if ($SessionId) {
    Set-Content -Path (Join-Path $claudeDir ".state_$SessionId") -Value "waiting" -NoNewline -ErrorAction SilentlyContinue

    $ctxPct = $json.context_window.used_percentage
    if ($ctxPct) {
        Set-Content -Path (Join-Path $claudeDir ".ctx_pct_$SessionId") -Value $ctxPct -NoNewline -ErrorAction SilentlyContinue
    }
}

# -- Auto-handoff: save dirty state -----------------------
if (-not $Dir) { exit }

try {
    Push-Location $Dir
    $isGit = git rev-parse --is-inside-work-tree 2>$null
    if ($isGit -ne "true") { Pop-Location; exit }

    $dirty = (git status --porcelain 2>$null | Measure-Object).Count
    $branch = git branch --show-current 2>$null

    if ($dirty -gt 0) {
        $changed = (git status --porcelain 2>$null | Select-Object -First 10 |
            ForEach-Object { ($_ -split '\s+', 2)[1] }) -join ', '

        $handoffDir = Join-Path $Dir ".claude"
        if (-not (Test-Path $handoffDir)) { New-Item -ItemType Directory -Path $handoffDir -Force | Out-Null }

        $handoffFile = Join-Path $handoffDir "handoff.md"
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"

        $content = Get-Content $handoffFile -Raw -ErrorAction SilentlyContinue
        if (-not $content -or $content -notmatch [regex]::Escape("Auto-saved $timestamp")) {
            Add-Content -Path $handoffFile -Value "`n## Auto-saved $timestamp"
            Add-Content -Path $handoffFile -Value "- Branch: $branch"
            Add-Content -Path $handoffFile -Value "- $dirty uncommitted changes: $changed"
        }

        Pop-Location
        @{ systemMessage = "Auto-saved session state to handoff.md ($dirty uncommitted changes on $branch)" } | ConvertTo-Json -Compress
    } else {
        Pop-Location
    }
} catch { Pop-Location }

exit 0
