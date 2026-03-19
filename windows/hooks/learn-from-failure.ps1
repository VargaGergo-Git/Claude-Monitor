# Self-healing: log build failures and nudge after repeated errors
# Hook type: PostToolUseFailure (matcher: Bash)
# PowerShell version for native Windows Claude Code

$Input = $input | Out-String
$json = $Input | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

if ($json.tool_name -ne "Bash") { exit }

$response = $json.tool_response
if (-not $response) { exit }

# Check for errors
$errorMatch = ""
$lines = $response -split "`n"
$errorLines = $lines | Where-Object { $_ -match "error:" -or $_ -match "failed" } | Select-Object -First 3
if ($errorLines) {
    $errorMatch = ($errorLines -join " ").Substring(0, [Math]::Min(($errorLines -join " ").Length, 300))
}

if (-not $errorMatch) { exit }

# Log the failure
$lessonsFile = Join-Path $env:USERPROFILE ".claude\.build_failures.log"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm"
Add-Content -Path $lessonsFile -Value "[$timestamp] $errorMatch" -ErrorAction SilentlyContinue

# Count recent failures
$recent = 0
if (Test-Path $lessonsFile) {
    $recent = (Get-Content $lessonsFile -Tail 20 -ErrorAction SilentlyContinue | Measure-Object).Count
}

if ($recent -ge 3) {
    @{ systemMessage = "Build has failed $recent times recently. Check ~/.claude/.build_failures.log for patterns." } | ConvertTo-Json -Compress
}
