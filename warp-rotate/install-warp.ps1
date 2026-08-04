# install-warp.ps1 - One-shot Cloudflare WARP install + register + connect for the
# OpenCode free fallback package. Idempotent: safe to run any time.
#   - Already installed -> just ensure registered + Connected.
#   - Not installed     -> download official MSI, silent-install (elevates if needed),
#                          register the device, connect, wait for the tunnel.
# Exit codes: 0 success, 1 failure (message printed).
param()

$ErrorActionPreference = "Continue"
$Warp = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
$Msiexec = "$env:WINDIR\System32\msiexec.exe"
# Official Cloudflare URLs: the "ga" endpoint always redirects to the current release.
$DownloadUrl = "https://downloads.cloudflareclient.com/v1/download/windows/ga"
$MsiPath = Join-Path $env:TEMP "Cloudflare_WARP_Release-x64.msi"

function Write-Status([string]$Msg) {
    Write-Host $Msg -ForegroundColor Cyan
}

function Test-Admin {
    try {
        $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Wait-WarpCli([int]$MaxSeconds = 120) {
    $elapsed = 0
    while ($elapsed -lt $MaxSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        if (Test-Path $Warp) { return $true }
    }
    return $false
}

function Wait-WarpConnected([int]$MaxSeconds = 90) {
    $elapsed = 0
    while ($elapsed -lt $MaxSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        if ((& $Warp status 2>$null) -match "Connected") { return $true }
    }
    return $false
}

# 0. Already installed?
if (Test-Path $Warp) {
    Write-Status "WARP already installed ($Warp)."
} else {
    Write-Status "WARP not installed. Downloading official installer..."

    # Installation needs an elevated shell; relaunch ourselves if we're not admin.
    if (-not (Test-Admin)) {
        Write-Status "Admin required for install - relaunching elevated..."
        try {
            $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
            Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait
        } catch {
            Write-Host "Elevation failed/cancelled. Install Cloudflare WARP manually from https://one.one.one.one/ then re-run setup." -ForegroundColor Red
            exit 1
        }
        # After the elevated run: did it install?
        if (Test-Path $Warp) { Write-Status "WARP installed by elevated run." }
        else { Write-Host "WARP still not installed after elevation attempt." -ForegroundColor Red; exit 1 }
    } else {
        # We ARE admin: download + install directly.
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $MsiPath -TimeoutSec 300
        } catch {
            Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path $MsiPath)) {
            Write-Host "Download produced no file - install failed." -ForegroundColor Red
            exit 1
        }
        Write-Status "Installing WARP silently (msiexec /qn)..."
        $proc = Start-Process -FilePath $Msiexec -ArgumentList "/i", "`"$MsiPath`"", "/qn", "/norestart" -Wait -PassThru
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            Write-Host "msiexec failed with exit code $($proc.ExitCode). Install Cloudflare WARP manually from https://one.one.one.one/." -ForegroundColor Red
            exit 1
        }
        Write-Status "Waiting for warp-cli to appear..."
        if (-not (Wait-WarpCli)) {
            Write-Host "warp-cli.exe not found after install." -ForegroundColor Red
            exit 1
        }
    }
}

# 1. Register the device (anonymous free registration; needed before connect).
Write-Status "Registering WARP device..."
& $Warp registration new 2>$null | Out-Null
Start-Sleep -Seconds 2
& $Warp register 2>$null | Out-Null   # older CLI name; harmless if unknown
Start-Sleep -Seconds 2

# 2. Connect and wait for the tunnel.
$status = (& $Warp status 2>$null) -join " "
if ($status -match "Connected") {
    Write-Status "WARP already Connected."
} else {
    Write-Status "Connecting WARP..."
    & $Warp connect 2>$null | Out-Null
    if (Wait-WarpConnected 90) { Write-Status "WARP Connected OK." }
    else { Write-Host "WARP did not reach Connected (status: $((& $Warp status 2>$null) -join ' ')). Re-run later - the watchdog will keep retrying." -ForegroundColor Yellow }
}

Write-Status "Done. Public IP: $(& { try { ((Invoke-WebRequest -UseBasicParsing -Uri 'https://1.1.1.1/cdn-cgi/trace' -TimeoutSec 10).Content -split '`n' | Where-Object { $_ -match '^ip=' }) -replace '^ip=','' } catch { 'unknown' } })"
exit 0
