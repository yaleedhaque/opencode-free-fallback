# rotate-warp.ps1 - Rotate Cloudflare WARP registration to obtain a new public IP.
# Called by opencode-warp-watch.ps1 when Big Pickle hits Zen's free IP quota.
# Requires: Cloudflare WARP client for Windows (https://one.one.one.one/).
#            warp-cli does NOT need admin (it talks to the CloudflareWARP service).
param(
    [string]$Reason = "manual"
)

$ErrorActionPreference = "Continue"
$Warp = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Dir "warp-rotate.log"
$StateFile = Join-Path $Dir "last-rotation.json"

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Get-PubIp {
    try {
        $t = (Invoke-WebRequest -UseBasicParsing -Uri "https://1.1.1.1/cdn-cgi/trace" -TimeoutSec 15).Content
        $ip = (($t -split "`n" | Where-Object { $_ -match "^ip=" }) -replace "^ip=", "") | Select-Object -First 1
        return $ip.Trim()
    } catch { return $null }
}

function Get-WarpStatus {
    try { return ((& $Warp status 2>$null) -join " ") } catch { return "" }
}

Write-Log "[$Reason] rotation started (status=$($(Get-WarpStatus)))"

if (-not (Test-Path $Warp)) {
    Write-Log "[$Reason] ERROR: warp-cli not found at $Warp"
    exit 1
}

$before = Get-PubIp
Write-Log "[$Reason] current public IP: $before"

$newIp = $before
$attempts = 0
$connected = $false

while ($attempts -lt 3 -and $newIp -eq $before) {
    $attempts++
    Write-Log "[$Reason] rotation attempt $attempts/3"

    if (Get-WarpStatus -match "Connected") { & $Warp disconnect 2>$null | Out-Null }
    Start-Sleep -Seconds 2
    & $Warp registration delete 2>$null | Out-Null
    Start-Sleep -Seconds 1
    & $Warp registration new 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Warp connect 2>$null | Out-Null

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if (Get-WarpStatus -match "Connected") { $connected = $true; break }
    }
    Start-Sleep -Seconds 3
    $newIp = Get-PubIp
    Write-Log "[$Reason] attempt ${attempts}: connected=$connected new IP=$newIp"
}

if (-not $connected) {
    Write-Log "[$Reason] FAILED: WARP did not reach Connected state after rotation"
    exit 1
}

if ($newIp -and $newIp -ne $before) {
    Write-Log "[$Reason] SUCCESS: IP rotated $before -> $newIp"
} else {
    Write-Log "[$Reason] WARNING: IP unchanged ($before) after $attempts attempt(s); WARP may have reissued the same address"
}

@{ "lastRotation" = (Get-Date).ToString("o"); "before" = $before; "after" = $newIp; "reason" = $Reason } |
    ConvertTo-Json -Compress | Out-File -FilePath $StateFile -Encoding utf8

exit 0
