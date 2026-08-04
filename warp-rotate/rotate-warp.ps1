# rotate-warp.ps1 - Rotate Cloudflare WARP registration to obtain a new public IP.
# Called by opencode-warp-watch.ps1 when Big Pickle hits Zen's free IP quota.
# Requires: Cloudflare WARP client for Windows (https://one.one.one.one/).
#            warp-cli does NOT need admin (it talks to the CloudflareWARP service).
# Self-heals: if WARP is disconnected when rotation is requested, it reconnects
# WARP first (waiting for the tunnel to reach "Connected"), then rotates.
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
    # Retry the probe a few times: right after WARP connects, the tunnel route is
    # still settling and the first request can fail (timeout / empty reply).
    for ($i = 1; $i -le 5; $i++) {
        try {
            $t = (Invoke-WebRequest -UseBasicParsing -Uri "https://1.1.1.1/cdn-cgi/trace" -TimeoutSec 15).Content
            $ip = (($t -split "`n" | Where-Object { $_ -match "^ip=" }) -replace "^ip=", "") | Select-Object -First 1
            $ip = "$ip".Trim()
            if ($ip) { return $ip }
        } catch { }
        Start-Sleep -Seconds 3
    }
    return $null
}

function Get-WarpStatus {
    try { return ((& $Warp status 2>$null) -join " ") } catch { return "" }
}

function Wait-WarpConnected([int]$MaxSeconds = 90) {
    # WARP does a "happy eyeballs" handshake to its gateway before the tunnel is up;
    # poll until status shows Connected (not merely "Connecting").
    $elapsed = 0
    while ($elapsed -lt $MaxSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        if (Get-WarpStatus -match "Connected") { return $true }
    }
    return $false
}

function Invoke-Connect {
    & $Warp connect 2>$null | Out-Null
    Start-Sleep -Seconds 5
    if (Get-WarpStatus -match "Connected") { return $true }
    return (Wait-WarpConnected 45)
}

Write-Log "[$Reason] rotation started (status=$($(Get-WarpStatus)))"

if (-not (Test-Path $Warp)) {
    Write-Log "[$Reason] ERROR: warp-cli not found at $Warp"
    exit 1
}

# If WARP dropped, bring it back BEFORE touching the registration, so the
# rotation starts from a working tunnel instead of a dead one.
if (Get-WarpStatus -notmatch "Connected") {
    Write-Log "[$Reason] WARP not connected - connecting first"
    if (-not (Invoke-Connect)) {
        Write-Log "[$Reason] FAILED: WARP could not reach Connected state (rotate when WARP is back up)"
        exit 1
    }
    Write-Log "[$Reason] WARP connected OK"
}

$before = Get-PubIp
Write-Log "[$Reason] current public IP: $before"

$newIp = $null
$attempts = 0
$connected = $true

while ($attempts -lt 3 -and ($null -eq $newIp -or $newIp -eq $before)) {
    $attempts++
    Write-Log "[$Reason] rotation attempt $attempts/3"

    if (Get-WarpStatus -match "Connected") { & $Warp disconnect 2>$null | Out-Null }
    Start-Sleep -Seconds 2
    & $Warp registration delete 2>$null | Out-Null
    Start-Sleep -Seconds 1
    & $Warp registration new 2>$null | Out-Null
    Start-Sleep -Seconds 2
    & $Warp connect 2>$null | Out-Null

    if (-not (Wait-WarpConnected 90)) {
        $connected = $false
        Write-Log "[$Reason] attempt ${attempts}: WARP never reached Connected, reconnecting"
        if (Invoke-Connect) { $connected = $true }
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
