# flip.ps1 - Rotate the egress public IP of your own VPN VM (replaces WARP rotation).
# Calls the tiny HTTP trigger installed by vps-setup.sh on the Oracle free VM.
# Use it manually, or wire it into the watcher so fallbacks auto-rotate the VPS IP.
# Usage:
#   .\flip.ps1 -Base "http://<vps-public-ip>:8099" -Key "<EGRESS_ROTATE_KEY from setup output>"
param(
    [string]$Base = "",
    [string]$Key = ""
)

if (-not $Base -or -not $Key) {
    Write-Host "Usage: .\flip.ps1 -Base http://<vps-ip>:8099 -Key <key> (both printed by vps-setup.sh)" -ForegroundColor Yellow
    exit 1
}

$url = "$Base/rotate?key=$Key"
try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 35
    if ($r.StatusCode -eq 200) {
        $newIp = (($r.Content -split "`n" | Where-Object { $_ -match "^ip=" }) -replace "^ip=", "") | Select-Object -First 1
        Write-Host "VPS egress rotated. New public IP: $newIp" -ForegroundColor Green
        exit 0
    } else {
        Write-Host "Trigger returned HTTP $($r.StatusCode)" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "rotate failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
