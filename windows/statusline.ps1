# Claude Code Status Line -- Windows PowerShell version
# Rich terminal status bar with usage tracking
#
# Add to your ~/.claude/settings.json:
# "statusLine": { "type": "command", "command": "powershell -ExecutionPolicy Bypass -File %USERPROFILE%\\.claude\\statusline.ps1", "padding": 4 }
$ErrorActionPreference = "SilentlyContinue"

# Force UTF-8 output so Unicode progress bars and symbols render correctly.
# PS 5.1 defaults to the OEM code page which corrupts them.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$InputData = ""
if ([Console]::IsInputRedirected) {
    $InputData = [Console]::In.ReadToEnd()
}
$json = $InputData | ConvertFrom-Json
if (-not $json) { exit }

# -- ESC character (works in PowerShell 5.1+) ----------------
$e = [char]27

# -- Parse ---------------------------------------------------
$Model = if ($json.model.display_name) { $json.model.display_name } else { "Claude" }
$SettingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
$Effort = "default"
$Fast = $false
if (Test-Path $SettingsPath) {
    $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
    if ($settings.effortLevel) { $Effort = $settings.effortLevel }
    if ($settings.fastMode -eq $true) { $Fast = $true }
}
$Pct = [int]($json.context_window.used_percentage -replace '\..*', '')
$Dir = $json.workspace.current_dir
$Proj = if ($Dir) { Split-Path $Dir -Leaf } else { "" }

# -- Git -----------------------------------------------------
$Branch = ""
$Dirty = 0
if ($Dir -and (Test-Path $Dir)) {
    Push-Location $Dir
    $Branch = git branch --show-current 2>$null
    $Dirty = (git status --porcelain 2>$null | Measure-Object).Count
    Pop-Location
}

# -- Fetch plan usage (cached 5min) --------------------------
$Cache = Join-Path $env:USERPROFILE ".claude\.usage_cache.json"
$CacheAge = 999
if (Test-Path $Cache) {
    $CacheAge = ((Get-Date) - (Get-Item $Cache).LastWriteTime).TotalSeconds
}

if ($CacheAge -ge 300) {
    $Token = ""
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinCredSL {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CredRead(string target, int type, int reserved, out IntPtr cred);
    [DllImport("advapi32.dll")]
    public static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public int Flags; public int Type;
        public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount;
        public IntPtr Attributes; public string TargetAlias; public string UserName;
    }
    public static string GetPassword(string target) {
        IntPtr ptr;
        if (!CredRead(target, 1, 0, out ptr)) return null;
        var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
        string pass = null;
        if (cred.CredentialBlobSize > 0) {
            // Try UTF-16 first (standard Windows credential encoding)
            pass = Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
            // If it doesn't look like JSON, try UTF-8 (Node.js apps often store UTF-8)
            if (pass == null || !pass.TrimStart().StartsWith("{")) {
                byte[] bytes = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
                pass = Encoding.UTF8.GetString(bytes);
            }
        }
        CredFree(ptr);
        return pass;
    }
}
"@ -ErrorAction SilentlyContinue

        # Try multiple credential target names (Claude Code may vary)
        $credJson = $null
        foreach ($target in @("Claude Code-credentials", "claude-code-credentials", "Claude Code/credentials")) {
            $credJson = [WinCredSL]::GetPassword($target)
            if ($credJson -and $credJson.TrimStart().StartsWith('{')) { break }
            $credJson = $null
        }
        if ($credJson) {
            $credObj = $credJson | ConvertFrom-Json
            $Token = $credObj.claudeAiOauth.accessToken
        }
    } catch {}

    if ($Token) {
        try {
            $headers = @{
                "Authorization" = "Bearer $Token"
                "anthropic-beta" = "oauth-2025-04-20"
            }
            $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/api/oauth/usage" -Headers $headers -TimeoutSec 3
            $resp | ConvertTo-Json -Depth 5 | Set-Content $Cache
        } catch {
            if (Test-Path $Cache) { (Get-Item $Cache).LastWriteTime = Get-Date }
        }
    }
}

# -- Parse usage ---------------------------------------------
$SessionPct = 0; $WeeklyPct = 0
$SessReset = ""; $WeekReset = ""; $WeekDelta = 0

if (Test-Path $Cache) {
    $usage = Get-Content $Cache -Raw | ConvertFrom-Json
    $SessionPct = [int]($usage.five_hour.utilization)
    $WeeklyPct = [int]($usage.seven_day.utilization)

    $WeekStartFile = Join-Path $env:USERPROFILE ".claude\.weekly_start_pct"
    if (-not (Test-Path $WeekStartFile)) { Set-Content -Path $WeekStartFile -Value $WeeklyPct }
    $WeekStartPct = [int](Get-Content $WeekStartFile)
    $WeekDelta = $WeeklyPct - $WeekStartPct
    if ($WeekDelta -lt 0) { $WeekDelta = 0 }

    if ($usage.five_hour.resets_at) {
        try {
            $resetTime = [DateTimeOffset]::Parse($usage.five_hour.resets_at)
            $remaining = ($resetTime - [DateTimeOffset]::Now).TotalSeconds
            if ($remaining -gt 0) {
                $h = [int]($remaining / 3600)
                $m = [int](($remaining % 3600) / 60)
                $SessReset = "${h}h${m}m"
            }
        } catch {}
    }

    if ($usage.seven_day.resets_at) {
        try {
            $resetTime = [DateTimeOffset]::Parse($usage.seven_day.resets_at)
            $WeekReset = $resetTime.LocalDateTime.ToString("ddd HH:mm")
        } catch {}
    }
}

# -- ANSI Palette (using $e = [char]27 for PS 5.1 compat) ----
$R = "$e[0m"; $B = "$e[1m"
$FG_BRAND    = "$e[38;2;255;150;70m"
$FG_MODEL    = "$e[38;2;200;195;185m"
$FG_PROJ     = "$e[38;2;235;235;248m"
$FG_GIT      = "$e[38;2;100;220;195m"
$FG_DIRTY    = "$e[38;2;255;190;70m"
$FG_OK       = "$e[38;2;120;220;155m"
$FG_MID      = "$e[38;2;245;195;75m"
$FG_HOT      = "$e[38;2;245;115;100m"
$FG_DIM      = "$e[38;2;80;80;105m"
$FG_MUTED    = "$e[38;2;42;42;55m"
$FG_SESS     = "$e[38;2;175;145;240m"
$FG_WEEK     = "$e[38;2;105;175;245m"
$FG_SEP      = "$e[38;2;45;45;62m"
$FG_CTX      = "$e[38;2;140;210;180m"
$FG_EFF_LO   = "$e[38;2;90;200;160m"
$FG_EFF_MED  = "$e[38;2;220;195;90m"
$FG_EFF_HI   = "$e[38;2;240;130;90m"
$FG_FAST_ON  = "$e[38;2;255;150;70m"
$FG_FAST_OFF = "$e[38;2;80;80;105m"
$FG_AGENT    = "$e[38;2;180;140;255m"
$FG_AGDESC   = "$e[38;2;130;110;180m"
$BG_BAR      = "$e[48;2;18;18;26m"
$SEP = "${FG_SEP} | ${R}${BG_BAR}"

# -- Helpers -------------------------------------------------
function Pick-UsageFg($p, $labelColor) {
    if ($p -ge 80) { return $FG_HOT }
    if ($p -ge 50) { return $FG_MID }
    return $labelColor
}

function Make-Bar($p, $n, $fg) {
    $f = [int]($p * $n / 100)
    if ($f -gt $n) { $f = $n }
    $filled = [string]::new([char]0x2501, $f)    # heavy horizontal =
    $empty  = [string]::new([char]0x2500, $n - $f)  # light horizontal -
    return "${fg}${filled}${FG_MUTED}${empty}"
}

# -- Effort --------------------------------------------------
$EffFg = $FG_DIM; $EffLabel = ""
switch ($Effort) {
    { $_ -in "low","min" }   { $EffFg = $FG_EFF_LO;  $EffLabel = "Low" }
    { $_ -in "high","max" }  { $EffFg = $FG_EFF_HI;  $EffLabel = "High" }
    "medium"                 { $EffFg = $FG_EFF_MED; $EffLabel = "Medium" }
}

# -- Line 1: Project + Model + Git + Context -----------------
$L1 = "${BG_BAR} "
$L1 += "${FG_BRAND}${B}$([char]0x25C6)${R}${BG_BAR} ${FG_PROJ}${B}${Proj}${R}${BG_BAR} ${FG_DIM}$([char]0xB7)${R}${BG_BAR} ${FG_MODEL}${Model}${R}${BG_BAR}"

if ($Branch) {
    $L1 += "${SEP}${FG_GIT}${Branch}${R}${BG_BAR}"
    if ($Dirty -gt 0) { $L1 += " ${FG_DIRTY}$([char]0x25CF)${R}${BG_BAR}" }
}

$ctxFg = Pick-UsageFg $Pct $FG_CTX
$ctxBar = Make-Bar $Pct 20 $ctxFg
$L1 += "${SEP}${FG_DIM}context${R}${BG_BAR} ${ctxBar}${R}${BG_BAR} ${ctxFg}${B}${Pct}%${R}${BG_BAR}"

if ($EffLabel) { $L1 += "${SEP}${EffFg}${EffLabel}${R}${BG_BAR}" }

if ($Fast) {
    $L1 += "${SEP}${FG_FAST_ON}${B}$([char]0x26A1)Fast${R}${BG_BAR}"
} else {
    $L1 += "${SEP}${FG_FAST_OFF}$([char]0x26A1)Off${R}${BG_BAR}"
}
$L1 += " ${R}"

# -- Line 2: Session + Weekly usage --------------------------
$L2 = "${BG_BAR} "

$sessFg = Pick-UsageFg $SessionPct $FG_SESS
$sessBar = Make-Bar $SessionPct 24 $sessFg
$L2 += "${FG_SESS}Session${R}${BG_BAR} ${sessBar}${R}${BG_BAR} ${sessFg}${B}${SessionPct}%${R}${BG_BAR}"
if ($SessReset) { $L2 += " ${FG_DIM}${SessReset}${R}${BG_BAR}" }

$weekFg = Pick-UsageFg $WeeklyPct $FG_WEEK
$weekBar = Make-Bar $WeeklyPct 24 $weekFg
$L2 += "${SEP}${FG_WEEK}Weekly${R}${BG_BAR} ${weekBar}${R}${BG_BAR} ${weekFg}${B}${WeeklyPct}%${R}${BG_BAR}"
if ($WeekDelta -gt 0) { $L2 += " ${FG_DIM}+${WeekDelta}%${R}${BG_BAR}" }
if ($WeekReset) { $L2 += " ${FG_DIM}${WeekReset}${R}${BG_BAR}" }

if (Test-Path $Cache) {
    $ago = ((Get-Date) - (Get-Item $Cache).LastWriteTime).TotalSeconds
    $refreshLabel = if ($ago -lt 60) { "just now" }
        elseif ($ago -lt 3600) { "$([int]($ago/60))m ago" }
        else { "$([int]($ago/3600))h ago" }
    $L2 += " ${FG_DIM}$([char]0xB7) ${refreshLabel}${R}${BG_BAR}"
}
$L2 += " ${R}"

# -- Active Agents line --------------------------------------
$AgentLine = ""
$AgentsFile = Join-Path $env:USERPROFILE ".claude\.agent_activity"
$AgentCount = 0
$counterFile = Join-Path $env:USERPROFILE ".claude\.active_agents"
if (Test-Path $counterFile) { $AgentCount = [int](Get-Content $counterFile) }

if ($AgentCount -gt 0) {
    $agentDescs = ""
    if (Test-Path $AgentsFile) {
        Get-Content $AgentsFile | ForEach-Object {
            $parts = $_ -split '\|', 2
            if ($parts.Count -eq 2 -and $parts[1]) {
                $short = $parts[1].Substring(0, [Math]::Min($parts[1].Length, 25))
                $agentDescs = if ($agentDescs) { "$agentDescs, $short" } else { $short }
            }
        }
    }
    $suffix = if ($AgentCount -gt 1) { "s" } else { "" }
    $AgentLine = "${BG_BAR} ${FG_AGENT}${B}$([char]0x25C6) $AgentCount agent${suffix}${R}${BG_BAR}"
    if ($agentDescs) { $AgentLine += " ${FG_AGDESC}${agentDescs}${R}${BG_BAR}" }
    if ($SessionPct -gt 0) { $AgentLine += " ${FG_DIM}$([char]0xB7) session ${SessionPct}% used${R}${BG_BAR}" }
    $AgentLine += " ${R}"
}

# -- Output to STDOUT (not Write-Host!) -----------------------
# Claude Code reads stdout from statusLine commands.
# Use a StreamWriter with explicit UTF-8 encoding -- PS 5.1's
# [Console]::OutputEncoding doesn't reliably override the pipe encoding,
# and the OEM code page (CP852 for Hungarian) garbles Unicode chars.
$utf8 = New-Object System.Text.UTF8Encoding $false
$writer = New-Object System.IO.StreamWriter([Console]::OpenStandardOutput(), $utf8)
$writer.AutoFlush = $true
$writer.WriteLine($L1)
$writer.WriteLine($L2)
if ($AgentLine) { $writer.WriteLine($AgentLine) }
$writer.Flush()
