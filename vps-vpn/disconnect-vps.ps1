# disconnect-vps.ps1 - Stop and remove your own VPN tunnel service (restore normal internet).
# Requires admin once. Idempotent.
param([string]$Conf = "")

if (-not $Conf) {
    $Candidate = Join-Path $PSScriptRoot "vps.conf"
    if (Test-Path $Candidate) { $Conf = $Candidate }
}
if (-not (Test-Path $Conf)) { Write-Host "vps.conf not found - nothing to remove." -ForegroundColor Yellow; exit 0 }

$base = Split-Path -Leaf $Conf
$svc = "WireGuardTunnel`$$base"
$WireGuard = "C:\Program Files\WireGuard\wireguard.exe"

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Elevating to remove tunnel service..."
    Start-Process powershell -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"","-Conf","`"$Conf`"" -Verb RunAs -Wait
    exit $LASTEXITCODE
}

if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
    Stop-Service -Name $svc -ErrorAction SilentlyContinue
    Start-Process $WireGuard -ArgumentList "/uninstalltunnelservice", "`"$Conf`"" -Wait -NoNewWindow
    Write-Host "Tunnel service removed. Your internet is back to normal (WARP/ISP)." -ForegroundColor Green
} else {
    Write-Host "No tunnel service installed." -ForegroundColor Yellow
}
exit 0
