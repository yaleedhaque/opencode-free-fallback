# setup-windows.ps1 - ONE command to install everything for OpenCode free fallback.
#   powershell -ExecutionPolicy Bypass -File setup-windows.ps1
#
# Asks which IP-rotation method you want, then does everything automatically:
#   1. Installs the opencode-runtime-fallback plugin + copies the chain config
#   2. Copies all WARP/VPS rotation scripts into ~/.config/opencode/
#   3. Rotation mode:
#        A) Own VPN (recommended) - guided: free Oracle VM + WireGuard dedicated IP
#        B) Cloudflare WARP        - quick, shared IPs (auto-installs if missing)
#        C) None                   - fallback chain only (Google/OpenRouter carry you)
#   4. Registers watcher autostart (logon) + 5-min self-healing watchdog
#   5. Installs the /fallback-status command + verify-chain churn guard
param()

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:USERPROFILE ".config\opencode"
$WarpDir = Join-Path $ConfigDir "warp-rotate"

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host " OpenCode Free Fallback - one-command setup" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# 0. Preflight: opencode must be on PATH
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: opencode not found on PATH. Install it first (https://opencode.ai)." -ForegroundColor Red
    exit 1
}

# 1. Install the fallback plugin globally
Write-Host ""
Write-Host "[1/5] Installing fallback plugin..." -ForegroundColor Yellow
opencode plugin opencode-runtime-fallback -g
if ($LASTEXITCODE -ne 0) {
    Write-Host "Plugin install failed. Add it manually to opencode.jsonc:  `"plugin`: [`"opencode-runtime-fallback`"]" -ForegroundColor Red
} else {
    Write-Host "[1/5] Plugin installed." -ForegroundColor Green
}

# 2. Copy the chain config
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $RepoDir "opencode-fallback.jsonc") -Destination (Join-Path $ConfigDir "opencode-fallback.jsonc") -Force
Write-Host "[2/5] Chain config copied." -ForegroundColor Green

# 3. Copy ALL rotation scripts (WARP + VPS) so the watcher can use either
New-Item -ItemType Directory -Path $WarpDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\rotate-warp.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\opencode-warp-watch.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\opencode-warp-start.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\install-warp.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\verify-chain.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\fallback-status.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "vps-vpn\flip.ps1") -Destination $WarpDir -Force
if (Test-Path (Join-Path $RepoDir "vps-vpn\vps-vpn.example.json")) {
    Copy-Item -LiteralPath (Join-Path $RepoDir "vps-vpn\vps-vpn.example.json") -Destination $WarpDir -Force
}
Write-Host "[3/5] Rotation scripts copied." -ForegroundColor Green

# 3b. Install the /fallback-status command
$cmdDir = Join-Path $ConfigDir "commands"
New-Item -ItemType Directory -Path $cmdDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoDir "commands\fallback-status.md") -Destination $cmdDir -Force

# 4. Ask which rotation method
$vpsJson = Join-Path $WarpDir "vps-vpn.json"
$hasVps = Test-Path $vpsJson
Write-Host ""
Write-Host "[4/5] Which IP-rotation method do you want?" -ForegroundColor Yellow
if ($hasVps) {
    Write-Host "  (A) Own VPN  - already configured, keeping it (recommended)"
} else {
    Write-Host "  (A) Own VPN  - dedicated free VM IP, most reliable (recommended)"
}
Write-Host "  (B) Cloudflare WARP - quick setup, shared IPs"
Write-Host "  (C) None - just the free fallback chain (Google/OpenRouter only)"
$mode = Read-Host "Choice [A/B/C]"
if ($mode -notmatch '^[AaBbCc]$') { $mode = "A" }

$warpExe = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
if ($mode -match '^[Aa]') {
    Write-Host ""
    Write-Host "Mode A: own VPN." -ForegroundColor Cyan
    if ($hasVps) {
        Write-Host "VPS already set up - skipping onboarding."
    } else {
        & (Join-Path $RepoDir "vps-vpn\bootstrap.ps1")
        if ($LASTEXITCODE -ne 0) {
            Write-Host "VPS setup did not finish - you can also pick mode B for WARP." -ForegroundColor Yellow
        }
    }
} elseif ($mode -match '^[Bb]') {
    Write-Host ""
    Write-Host "Mode B: Cloudflare WARP." -ForegroundColor Cyan
    if (-not (Test-Path $warpExe)) {
        Write-Host "WARP not installed - installing automatically (one-time admin prompt)..." -ForegroundColor Yellow
        & (Join-Path $WarpDir "install-warp.ps1")
    }
} else {
    Write-Host ""
    Write-Host "Mode C: no rotation. The Google/OpenRouter fallback lanes carry your sessions." -ForegroundColor Cyan
}

# 5. Watcher autostart + watchdog (self-heals every 5 min)
$startScript = Join-Path $WarpDir "opencode-warp-start.ps1"
if (Test-Path $startScript) {
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $startScript + '"'
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "opencode-warp-rotate" -Value $cmd
    Write-Host "[5/5] Watcher autostart registered (logon)." -ForegroundColor Green

    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $startScript + '"'
    schtasks /Create /F /TN "opencode-warp-watchdog" /SC MINUTE /MO 5 /TR $tr | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[5/5] Watchdog registered (self-heals every 5 min)." -ForegroundColor Green
    } else {
        Write-Host "NOTE: watchdog scheduled task failed (may need an admin shell once)." -ForegroundColor Yellow
    }

    Write-Host "Starting watcher now..."
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','"' + $startScript + '"' -WindowStyle Hidden
}

# In WARP mode, make sure WARP is on (needed for rotation).
if ($mode -match '^[Bb]' -and (Test-Path $warpExe)) {
    & $warpExe connect 2>$null | Out-Null
    Write-Host "WARP connect requested." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Setup complete ===" -ForegroundColor Green
Write-Host "  1. Keys (recommended): opencode auth login  -> Google AI Studio + OpenRouter (free)"
Write-Host "  2. Default model: opencode/big-pickle (see opencode.jsonc)"
Write-Host "  3. Restart opencode. Health check: /fallback-status"
Write-Host "  4. Model churn guard: powershell -File `"$WarpDir\verify-chain.ps1`""
Write-Host ""
Write-Host "Want it even easier? Re-run this file on any new PC - it's all one command." -ForegroundColor Cyan
