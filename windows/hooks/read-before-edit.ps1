# Safety gate: warn if editing a file that hasn't been read yet
# Hook type: PreToolUse (matcher: Edit|Write)
# PowerShell version for native Windows Claude Code

$InputData = [Console]::In.ReadToEnd()
$json = $InputData | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$tool = $json.tool_name
if ($tool -ne "Edit" -and $tool -ne "Write") { exit }

$file = $json.tool_input.file_path
if (-not $file) { exit }

$readLog = Join-Path $env:USERPROFILE ".claude\.files_read"
if (-not (Test-Path $readLog)) { Set-Content -Path $readLog -Value "" }

$reads = Get-Content $readLog -ErrorAction SilentlyContinue
$wasRead = $reads | Where-Object { $_ -eq $file }

if (-not $wasRead) {
    $fname = Split-Path $file -Leaf
    @{
        hookSpecificOutput = @{
            hookEventName = "PreToolUse"
            additionalContext = "Editing $fname without reading it first -- make sure you understand the full context."
        }
    } | ConvertTo-Json -Compress -Depth 3
}
