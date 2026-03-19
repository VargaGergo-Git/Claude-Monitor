# Claude Code Insights -- human-friendly narration of what Claude is doing
# Hook type: PreToolUse
# PowerShell version for native Windows Claude Code

$reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$InputData = $reader.ReadToEnd()
$json = $InputData | ConvertFrom-Json -ErrorAction SilentlyContinue
if (-not $json) { exit }

$Tool = $json.tool_name
$SessionId = $json.session_id
$msg = ""

# -- Helper: get tool input field -------------------------
function Get-Field($name) {
    try { $json.tool_input.$name } catch { "" }
}

# -- File descriptions ------------------------------------
function Describe-File($f) {
    switch -Wildcard ($f) {
        "*CLAUDE.md"         { "project rules" }
        "*README.md"         { "project README" }
        "*package.json"      { "package config" }
        "*Cargo.toml"        { "Cargo config" }
        "*settings.json"     { "settings" }
        "*config*"           { "configuration" }
        "*.test.*"           { "tests" }
        "*.spec.*"           { "specs" }
        "*.swift"            { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        "*.ts"               { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        "*.tsx"              { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        "*.py"               { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        "*.rs"               { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        "*.go"               { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        "*.md"               { "documentation" }
        "*.sh"               { "a script" }
        "*.ps1"              { "a PowerShell script" }
        default              { [System.IO.Path]::GetFileName($f) }
    }
}

# -- Main dispatch ----------------------------------------
switch ($Tool) {
    "Read" {
        $file = Get-Field "file_path"
        $what = Describe-File $file
        $msg = "Reading $what"
    }
    "Edit" {
        $file = Get-Field "file_path"
        $what = Describe-File $file
        $oldLen = (Get-Field "old_string").Length
        $newLen = (Get-Field "new_string").Length
        $ra = Get-Field "replace_all"

        if ($ra -eq "true") { $msg = "Renaming across $what" }
        elseif ($newLen -le 1) { $msg = "Removing code from $what" }
        elseif ($oldLen -lt 10 -and $newLen -gt 100) { $msg = "Adding new functionality to $what" }
        elseif ($newLen -gt $oldLen) { $msg = "Expanding $what" }
        elseif ($oldLen -gt $newLen) { $msg = "Simplifying $what" }
        else { $msg = "Tweaking $what" }
    }
    "Write" {
        $file = Get-Field "file_path"
        $what = Describe-File $file
        $lines = ((Get-Field "content") -split "`n").Count
        $msg = if ($lines -gt 100) { "Creating $what ($lines lines)" } else { "Creating $what" }
    }
    "Bash" {
        $cmd = Get-Field "command"
        $base = ($cmd -split ' ')[0] -replace '.+[\\/]', ''
        switch ($base) {
            "git" {
                $sub = ($cmd -split ' ')[1]
                $msg = switch ($sub) {
                    "status"   { "Checking what files have changed" }
                    "diff"     { "Reviewing the actual changes" }
                    "log"      { "Looking at recent commit history" }
                    "commit"   { "Saving changes as a commit" }
                    "push"     { "Pushing changes to remote" }
                    "pull"     { "Pulling latest from remote" }
                    "checkout" { "Switching branches" }
                    "branch"   { "Working with branches" }
                    "add"      { "Staging files for commit" }
                    default    { "Git operation" }
                }
            }
            { $_ -in "npm","yarn","pnpm" } {
                $sub = ($cmd -split ' ')[1]
                $msg = switch ($sub) {
                    { $_ -in "install","add","i" } { "Installing dependencies" }
                    "test"  { "Running tests" }
                    "build" { "Building the project" }
                    default { "Package manager: $sub" }
                }
            }
            "cargo" {
                $sub = ($cmd -split ' ')[1]
                $msg = switch ($sub) {
                    "build" { "Building with Cargo" }
                    "test"  { "Running Cargo tests" }
                    "run"   { "Running the project" }
                    default { "Cargo: $sub" }
                }
            }
            default { $msg = "Running a command" }
        }
    }
    "Glob" {
        $pat = Get-Field "pattern"
        $msg = switch -Wildcard ($pat) {
            "*test*"  { "Finding test files" }
            "*.ts"    { "Finding TypeScript files" }
            "*.py"    { "Finding Python files" }
            "*.rs"    { "Finding Rust files" }
            "*.go"    { "Finding Go files" }
            "*.md"    { "Finding documentation" }
            default   { "Searching for files" }
        }
    }
    "Grep" {
        $pat = Get-Field "pattern"
        if ($pat.Length -gt 40) { $pat = $pat.Substring(0, 40) }
        $msg = switch -Wildcard ($pat) {
            "*TODO*"    { "Looking for known issues" }
            "*import*"  { "Checking dependencies" }
            "*func *"   { "Finding a function definition" }
            "*class *"  { "Finding a type definition" }
            "*error*"   { "Hunting for error-prone code" }
            default     { "Searching code for `"$pat`"" }
        }
    }
    "Agent" {
        $desc = Get-Field "description"
        $bg = Get-Field "run_in_background"
        if ($desc) {
            $msg = if ($bg -eq "true") { "Background task: $desc" } else { "Sub-task: $desc" }
        } else {
            $msg = "Launching a helper agent"
        }
    }
    "WebFetch" {
        $url = Get-Field "url"
        if ($url -match 'https?://([^/]+)') { $msg = "Reading a page from $($Matches[1])" }
        else { $msg = "Fetching a web page" }
    }
    "WebSearch" {
        $q = Get-Field "query"
        if ($q.Length -gt 50) { $q = $q.Substring(0, 50) }
        $msg = "Searching the web: $q"
    }
}

# -- Write state files for Claude Monitor -----------------
if ($SessionId) {
    $claudeDir = Join-Path $env:USERPROFILE ".claude"

    if ($msg) {
        Set-Content -Path (Join-Path $claudeDir ".ctx_$SessionId") -Value $msg -NoNewline -ErrorAction SilentlyContinue
    }

    Set-Content -Path (Join-Path $claudeDir ".state_$SessionId") -Value "active" -NoNewline -ErrorAction SilentlyContinue

    # Rolling context log
    if ($msg) {
        $logPath = Join-Path $claudeDir ".ctxlog_$SessionId"
        Add-Content -Path $logPath -Value $msg -ErrorAction SilentlyContinue
        $lines = Get-Content $logPath -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt 8) {
            $lines | Select-Object -Last 8 | Set-Content $logPath -ErrorAction SilentlyContinue
        }
    }

    # Context percentage
    $ctxPct = $json.context_window.used_percentage
    if ($ctxPct) {
        Set-Content -Path (Join-Path $claudeDir ".ctx_pct_$SessionId") -Value $ctxPct -NoNewline -ErrorAction SilentlyContinue
    }

    # Activity timestamp
    $actLog = Join-Path $claudeDir ".activity_$SessionId"
    Add-Content -Path $actLog -Value ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -ErrorAction SilentlyContinue
    $actLines = Get-Content $actLog -ErrorAction SilentlyContinue
    if ($actLines -and $actLines.Count -gt 20) {
        $actLines | Select-Object -Last 20 | Set-Content $actLog -ErrorAction SilentlyContinue
    }
}

# -- Output -----------------------------------------------
if ($msg) {
    @{ systemMessage = $msg } | ConvertTo-Json -Compress
}
