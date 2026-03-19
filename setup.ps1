# Claude Monitor -- One-command setup for Windows
# Usage: irm https://raw.githubusercontent.com/VargaGergo-Git/Claude-Monitor/main/setup.ps1 | iex
$ErrorActionPreference = "Stop"

function Write-Info($msg)  { Write-Host "=> " -ForegroundColor Cyan -NoNewline; Write-Host $msg }
function Write-Ok($msg)    { Write-Host "[OK] " -ForegroundColor Green -NoNewline; Write-Host $msg }
function Write-Err($msg)   { Write-Host "[X] " -ForegroundColor Red -NoNewline; Write-Host $msg }

Write-Host ""
Write-Host "Claude Monitor" -ForegroundColor White -NoNewline
Write-Host " -- One-command setup" -ForegroundColor Gray
Write-Host ""

# Prerequisites
if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Err "git is required. Install from https://git-scm.com/download/win"
    exit 1
}

# Clone to temp directory (use user profile to avoid short-path issues with Unicode names)
$TmpDir = Join-Path $env:USERPROFILE ".claude-monitor-setup-$(Get-Random)"
try {
    Write-Info "Downloading Claude Monitor..."
    git clone --depth 1 --quiet https://github.com/VargaGergo-Git/Claude-Monitor.git $TmpDir 2>$null
    Write-Ok "Downloaded"

    # Run installer
    $installer = Join-Path $TmpDir "windows\install.ps1"
    & powershell -ExecutionPolicy Bypass -File $installer

    Write-Host ""
    Write-Ok "Setup complete -- Claude Monitor is ready"
} finally {
    # Cleanup temp directory
    try {
        if (Test-Path $TmpDir) {
            Remove-Item $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
