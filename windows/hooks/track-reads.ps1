# Track which files have been read (for read-before-edit gate)
# Hook type: PostToolUse (matcher: Read)
# PowerShell version for native Windows Claude Code

$Input = $input | Out-String
$json = $Input | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

if ($json.tool_name -ne "Read") { exit }

$file = $json.tool_input.file_path
if (-not $file) { exit }

$readLog = Join-Path $env:USERPROFILE ".claude\.files_read"
Add-Content -Path $readLog -Value $file -ErrorAction SilentlyContinue
