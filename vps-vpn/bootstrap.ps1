# bootstrap.ps1 - Guided onboarding for the "own VPN" option (dedicated IP).
# Walks anyone through: SSH into the Oracle free VM -> run vps-setup.sh -> pull back the
# client config -> install WireGuard -> disable WARP -> auto-wire the watcher to rotate
# the VPS IP. After this, everything is automatic.
#
# Run from the repo:  .\vps-vpn\bootstrap.ps1    (or via the setup wizard)

$ErrorActionPreference = "Continue"
$VpsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SetupSh = Join-Path $VpsDir "vps-setup.sh"
$ConfigRoot = Join-Path $env:USERPROFILE ".config\opencode"
$WarpDir = Join-Path $ConfigRoot "warp-rotate"
$LocalVps = Join-Path $ConfigRoot "vps-vpn"
$ConfPath = Join-Path $LocalVps "vps.conf"
$InfoPath = Join-Path $LocalVps "vps-info.txt"
$VpsJson = Join-Path $WarpDir "vps-vpn.json"

Write-Host ""
Write-Host "== Own VPN (dedicated IP) setup ==" -ForegroundColor Cyan
Write-Host "This connects your PC to a free Oracle Cloud VM so Big Pickle runs on a"
Write-Host "clean IP that only you burn. You need to have ALREADY created the VM:"
Write-Host "  https://signup.oraclecloud.com  -> Compute -> Instances -> Create instance"
Write-Host "  (Ubuntu 24.04, Ampere A1 / Micro, 'Always Free eligible', public IP yes,"
Write-Host "   download the SSH key pair it generates)"
Write-Host ""

if (Test-Path $VpsJson) {
    $ans = Read-Host "VPS already configured. Re-run setup anyway? [y/N]"
    if ($ans -notmatch '^y') { Write-Host "OK, keeping existing config." -ForegroundColor Green; exit 0 }
}

# --- 1. Gather VM details -------------------------------------------------
$vmIp = Read-Host "VM public IP (from the Oracle instance page)"
if (-not $vmIp) { Write-Host "No IP given - aborting." -ForegroundColor Red; exit 1 }

$user = Read-Host "SSH username (default: ubuntu)"
if (-not $user) { $user = "ubuntu" }

$defaultKey = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
$keyPath = Read-Host "Path to your downloaded SSH private key (.key file)"
if ($keyPath -and -not (Test-Path $keyPath)) {
    Write-Host "Key file not found: $keyPath" -ForegroundColor Red
    exit 1
}
if (-not $keyPath) {
    $candidates = Get-ChildItem "$defaultKey\*" -Include *.key -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidates) { $keyPath = $candidates.FullName }
}
if (-not (Test-Path $keyPath)) {
    Write-Host "No SSH key found - download it from the Oracle console (Create instance -> Download key pair)." -ForegroundColor Red
    exit 1
}

# --- 2. Verify SSH ---------------------------------------------------------
Write-Host ""
Write-Host "Testing SSH connection to $user@$vmIp ..." -ForegroundColor Yellow
$probe = & ssh -i $keyPath -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$user@$vmIp" "echo ok" 2>&1
if ($LASTEXITCODE -ne 0 -or $probe -notmatch "ok") {
    Write-Host "SSH failed. Check: VM running? Security list has TCP 22 open? Right key?" -ForegroundColor Red
    Write-Host "  (details: $($probe -join ' '))"
    exit 1
}
Write-Host "SSH OK." -ForegroundColor Green

# --- 3. Run the server setup on the VM -------------------------------------
New-Item -ItemType Directory -Path $LocalVps -Force | Out-Null
Write-Host ""
Write-Host "Uploading + running vps-setup.sh on the VM (installs WireGuard, ~2-5 min)..." -ForegroundColor Yellow
& scp -i $keyPath -o BatchMode=yes $SetupSh "$user@$vmIp`:/tmp/vps-setup.sh" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "scp failed." -ForegroundColor Red; exit 1 }
$setupOut = & ssh -i $keyPath -o BatchMode=yes "$user@$vmIp" "chmod +x /tmp/vps-setup.sh && /tmp/vps-setup.sh 2>&1" 2>&1
$setupOut | Out-File -FilePath (Join-Path $LocalVps "setup.log") -Encoding utf8
Write-Host ($setupOut | Select-Object -Last 30) -ForegroundColor Gray

# --- 4. Pull back the client config + rotation info ------------------------
Write-Host "Pulling back client config..."
& scp -i $keyPath -o BatchMode=yes "$user@$vmIp`:/home/$user/client.conf" $ConfPath 2>&1 | Out-Null
& scp -i $keyPath -o BatchMode=yes "$user@$vmIp`:/home/$user/vps-info.txt" $InfoPath 2>&1 | Out-Null
if (-not (Test-Path $ConfPath)) { Write-Host "client.conf did not come back - setup on the VM failed. See $LocalVps\setup.log" -ForegroundColor Red; exit 1 }

$info = Get-Content $InfoPath -ErrorAction SilentlyContinue
$url = ($info | Where-Object { $_ -match "^EGRESS_ROTATE_URL=" }) -replace "^EGRESS_ROTATE_URL=", ""
$key = ($info | Where-Object { $_ -match "^EGRESS_ROTATE_KEY=" }) -replace "^EGRESS_ROTATE_KEY=", ""
if (-not $url -or -not $key) {
    Write-Host "Rotation info missing from VM - falling back to WARP-only rotation (still works)." -ForegroundColor Yellow
    $url = ""; $key = ""
}

# --- 5. Save rotation config for the watcher -------------------------------
if ($url -and $key) {
    @{ "Base" = $url; "Key" = $key } | ConvertTo-Json | Out-File -FilePath $VpsJson -Encoding utf8
    Write-Host "Rotation config written (auto-rotate on fallback)." -ForegroundColor Green
}

# --- 6. Install WireGuard (Windows client) ----------------------------------
$wg = "C:\Program Files\WireGuard\wireguard.exe"
if (-not (Test-Path $wg)) {
    Write-Host "Installing WireGuard for Windows (free)..."
    $inst = & winget install --id WireGuard.WireGuard -e --accept-source-agreements --accept-package-agreements --silent 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "WireGuard install via winget failed. Install it manually from https://www.wireguard.com/install/ then re-run this." -ForegroundColor Yellow
        Write-Host "  ($($inst -join ' '))"
    }
}

# --- 7. Turn WARP off (VPS replaces it) -------------------------------------
$warp = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
if (Test-Path $warp) {
    Write-Host "Disabling WARP (replaced by your VPN)..."
    & $warp disconnect 2>$null | Out-Null
}
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (Test-Path "$runKey\opencode-warp-rotate") {
    # keep the watcher autostart (it now drives VPS rotation) but the watchdog no
    # longer re-connects WARP in VPS mode - nothing more to do here.
    Write-Host "Watcher autostart kept (now manages VPS rotation)."
}

# --- 8. Connect the tunnel ---------------------------------------------------
Write-Host ""
Write-Host "Enabling the tunnel (all your traffic will route through your VM)..."
& (Join-Path $VpsDir "connect-vps.ps1") -Conf $ConfPath

Write-Host ""
Write-Host "=== All done ===" -ForegroundColor Cyan
Write-Host " - WireGuard tunnel: enabled (auto-starts at boot)"
Write-Host " - Rotation: automatic on fallback (dedicated IP preferred, WARP as backup)"
Write-Host " - Check anytime: /fallback-status in opencode"
Write-Host " - Test rotation: powershell -File `"$VpsDir\flip.ps1`" -Base `"$url`" -Key `"$key`""
Write-Host " - Turn VPN off: powershell -File `"$VpsDir\disconnect-vps.ps1`""
exit 0
