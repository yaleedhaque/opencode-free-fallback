# fallback-status.ps1 - One-shot health report for the free-fallback system.
# Used by the /fallback-status opencode command (and can be run standalone).

$ErrorActionPreference = "Continue"
$ConfigDir = Join-Path $env:USERPROFILE ".config\opencode"
$WarpDir = Join-Path $ConfigDir "warp-rotate"
$Warp = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"

function Get-String([string]$Path, [string]$Key) {
    $raw = Get-Content $Path -Raw
    $m = [regex]::Match($raw, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-Scalar([string]$Path, [string]$Key) {
    $raw = Get-Content $Path -Raw
    $m = [regex]::Match($raw, '"' + [regex]::Escape($Key) + '"\s*:\s*([^,\r\n\]]+)')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

function Get-FallbackModels([string]$Path) {
    $raw = Get-Content $Path -Raw
    $m = [regex]::Match($raw, '"fallback_models"\s*:\s*\[(.*?)\]', 'Singleline')
    if (-not $m.Success) { return @() }
    $ids = [regex]::Matches($m.Groups[1].Value, '"([^"]+)"')
    return @($ids | ForEach-Object { $_.Groups[1].Value })
}

"# Free-Fallback System Status"
""

$ver = ((opencode --version 2>$null) | Select-Object -First 1).Trim()
"opencode version    : $ver"

$fcfg = Join-Path $ConfigDir "opencode-fallback.jsonc"
$ocfg = Join-Path $ConfigDir "opencode.jsonc"
$chain = @(Get-FallbackModels $fcfg)
"fallback plugin     : enabled=$(Get-Scalar $fcfg enabled) | chain=$($chain.Count) models | maxAttempts=$(Get-Scalar $fcfg max_fallback_attempts) | cooldown=$(Get-Scalar $fcfg cooldown_seconds)s | timeout=$(Get-Scalar $fcfg timeout_seconds)s"
"primary model       : $(Get-String $ocfg model)"
"small_model (chores): $(Get-String $ocfg small_model)"

if (Test-Path $Warp) {
    $ws = ((& $Warp status 2>$null) | Where-Object { $_ -notmatch '^\s*$' }) -join " | "
    $ip = $null
    try { $ip = ((Invoke-WebRequest -UseBasicParsing -Uri "https://1.1.1.1/cdn-cgi/trace" -TimeoutSec 10).Content -split "`n" | Where-Object { $_ -match '^ip=' } | Select-Object -First 1) -replace '^ip=', '' } catch {}
    "WARP                : $ws | pubIP=$ip"
} else {
    "WARP                : NOT INSTALLED"
}

$watcher = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*opencode-warp-watch.ps1*" })
if ($watcher.Count -gt 0) { "watcher             : RUNNING (pid $($watcher.ProcessId -join ','))" } else { "watcher             : NOT RUNNING" }

$stateFile = Join-Path $WarpDir "last-rotation.json"
if (Test-Path $stateFile) {
    try {
        $lr = Get-Content $stateFile -Raw | ConvertFrom-Json
        $ago = [math]::Round(((Get-Date) - [DateTime]::Parse($lr.lastRotation)).TotalHours, 1)
        "last IP rotation    : $($lr.lastRotation) ($ago h ago) | $($lr.before) -> $($lr.after) | reason=$($lr.reason)"
    } catch { "last IP rotation    : unreadable state file" }
} else {
    "last IP rotation    : never"
}

$fblog = Join-Path $ConfigDir "opencode-fallback.log"
if (Test-Path $fblog) {
    $ev = @(Select-String -Path $fblog -Pattern "Auto-retrying with fallback model" | Select-Object -Last 5)
    if ($ev.Count -gt 0) {
        "recent fallbacks    : $($ev.Count) seen (latest below)"
        $ev | ForEach-Object { "  " + $_.Line }
    } else {
        "recent fallbacks    : none yet"
    }
} else {
    "recent fallbacks    : no fallback log"
}

$watchLog = Join-Path $WarpDir "watch.log"
if (Test-Path $watchLog) {
    "last watcher events :"
    Get-Content $watchLog -Tail 4 | ForEach-Object { "  " + $_ }
}
