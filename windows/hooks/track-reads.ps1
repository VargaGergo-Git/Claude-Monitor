# Track which files have been read (for read-before-edit gate)
# Hook type: PostToolUse (matcher: Read)
# PowerShell version for native Windows Claude Code

$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$InputData = $reader.ReadToEnd()
$json = $InputData | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

if ($json.tool_name -ne "Read") { exit }

$file = $json.tool_input.file_path
if (-not $file) { exit }

$readLog = Join-Path $env:USERPROFILE ".claude\.files_read"
Add-Content -Path $readLog -Value $file -ErrorAction SilentlyContinue
