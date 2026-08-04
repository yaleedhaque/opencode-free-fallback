# connect-vps.ps1 - Enable your own VPN tunnel (WireGuard) as a Windows service.
# Installs the tunnel service (auto-starts at boot, no user action needed) if not present,
# then starts it. Requires admin once. Safe to re-run (idempotent).
param([string]$Conf = "")

$ErrorActionPreference = "Stop"
$WireGuard = "C:\Program Files\WireGuard\wireguard.exe"

if (-not $Conf) {
    $Candidate = Join-Path $PSScriptRoot "vps.conf"
    if (Test-Path $Candidate) { $Conf = $Candidate }
}
if (-not (Test-Path $Conf)) {
    Write-Host "vps.conf not found. Run bootstrap.ps1 first, or pass -Conf path\to\vps.conf" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $WireGuard)) {
    Write-Host "WireGuard not installed. Install it from https://www.wireguard.com/install/ (free), then re-run." -ForegroundColor Red
    exit 1
}

$base = Split-Path -Leaf $Conf
$svc = "WireGuardTunnel`$$base"

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Service install needs admin - relaunch elevated if needed.
if (-not (Test-Admin)) {
    Write-Host "Elevating for tunnel service install..."
    Start-Process powershell -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`"","-Conf","`"$Conf`"" -Verb RunAs -Wait
    exit $LASTEXITCODE
}

if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
    Write-Host "Tunnel service '$svc' already installed."
} else {
    Write-Host "Installing tunnel service '$svc'..."
    $p = Start-Process $WireGuard -ArgumentList "/installtunnelservice", "`"$Conf`"" -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        Write-Host "Failed to install tunnel service (exit $($p.ExitCode)). Check the config file." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Starting tunnel (all traffic will route through your VPS)..."
Start-Service -Name $svc
Start-Sleep -Seconds 4

try {
    $ip = ((Invoke-WebRequest -UseBasicParsing -Uri "https://1.1.1.1/cdn-cgi/trace" -TimeoutSec 10).Content -split "`n" | Where-Object { $_ -match "^ip=" }) -replace "^ip=", "" | Select-Object -First 1
    Write-Host "Connected. Public IP: $ip" -ForegroundColor Green
} catch {
    Write-Host "Tunnel started. Verify your IP at https://1.1.1.1/cdn-cgi/trace" -ForegroundColor Yellow
}
exit 0
