# setup-windows.ps1 - One-shot setup for the OpenCode free fallback + WARP IP rotation.
# 1. Installs the opencode-runtime-fallback plugin
# 2. Copies opencode-fallback.jsonc into the opencode config dir
# 3. Registers the WARP rotation watcher to auto-start at logon (HKCU Run, no admin needed)
param()

$ErrorActionPreference = "Stop"
$RepoDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:USERPROFILE ".config\opencode"
$WarpDir = Join-Path $ConfigDir "warp-rotate"

Write-Host "== OpenCode free fallback setup ==" -ForegroundColor Cyan

# 0. Preflight: opencode must be on PATH
if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: opencode not found on PATH. Install it first (https://opencode.ai)." -ForegroundColor Red
    exit 1
}

# 1. Install the fallback plugin globally
Write-Host "Installing opencode-runtime-fallback plugin..." -ForegroundColor Yellow
opencode plugin opencode-runtime-fallback -g
if ($LASTEXITCODE -ne 0) {
    Write-Host "Plugin install failed. Add it manually to your opencode.jsonc:  `"plugin`: [`"opencode-runtime-fallback`"]" -ForegroundColor Red
} else {
    Write-Host "Plugin installed." -ForegroundColor Green
}

# 2. Copy the fallback chain config
if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
Copy-Item -LiteralPath (Join-Path $RepoDir "opencode-fallback.jsonc") -Destination (Join-Path $ConfigDir "opencode-fallback.jsonc") -Force
Write-Host "Copied opencode-fallback.jsonc -> $ConfigDir\opencode-fallback.jsonc" -ForegroundColor Green

# 3. Copy the WARP scripts + register autostart
New-Item -ItemType Directory -Path $WarpDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\rotate-warp.ps1") -Destination $WarpDir -Force
Copy-Item -LiteralPath (Join-Path $RepoDir "warp-rotate\opencode-warp-watch.ps1") -Destination $WarpDir -Force
Write-Host "Copied WARP scripts -> $WarpDir" -ForegroundColor Green

$warpExe = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"
if (Test-Path $warpExe) {
    $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $WarpDir "opencode-warp-watch.ps1") + '"'
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "opencode-warp-rotate" -Value $cmd
    Write-Host "Registered watcher autostart (HKCU Run 'opencode-warp-rotate')." -ForegroundColor Green
    Write-Host "Starting watcher now..."
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + (Join-Path $WarpDir "opencode-warp-watch.ps1") + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Start-Process $warpExe -ArgumentList "connect" -WindowStyle Hidden
    Write-Host "WARP connect requested (needed for IP rotation)." -ForegroundColor Green
} else {
    Write-Host "NOTE: Cloudflare WARP not found. Download it from https://one.one.one.one/ to enable IP rotation." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Cyan
Write-Host "  1. Add free API keys (both optional but recommended):"
Write-Host "       opencode auth login   -> Google AI Studio key (free): https://aistudio.google.com/apikey"
Write-Host "       opencode auth login   -> OpenRouter key (free):       https://openrouter.ai/keys"
Write-Host "  2. Set your default model to opencode/big-pickle in opencode.jsonc"
Write-Host "  3. Restart opencode. Test the chain:  opencode models | findstr free"
