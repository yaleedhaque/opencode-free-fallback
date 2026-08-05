# make-watchdog-vbs.ps1 - Creates the silent watchdog launcher for the current user.
#
# Why: the 5-minute scheduled task runs opencode-warp-start.ps1. Launching it with
# powershell.exe -WindowStyle Hidden still flashes a console window for a split second
# on every run. This writes run-hidden-watchdog.vbs, which Task Scheduler runs via
# wscript.exe - wscript never creates a console, so the watchdog is 100% silent.
#
# Usage:
#   powershell -File make-watchdog-vbs.ps1
#   schtasks /Create /F /TN opencode-warp-watchdog /SC MINUTE /MO 5 /TR "wscript.exe `"$env:USERPROFILE\.config\opencode\warp-rotate\run-hidden-watchdog.vbs`""
param()

$ErrorActionPreference = "Stop"
$WarpDir = Join-Path $env:USERPROFILE ".config\opencode\warp-rotate"
$StartScript = Join-Path $WarpDir "opencode-warp-start.ps1"
$Vbs = Join-Path $WarpDir "run-hidden-watchdog.vbs"

if (-not (Test-Path $StartScript)) {
    Write-Host "ERROR: opencode-warp-start.ps1 not found at $StartScript" -ForegroundColor Red
    Write-Host "Run setup-windows.ps1 first to install the watcher scripts." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $WarpDir)) { New-Item -ItemType Directory -Path $WarpDir -Force | Out-Null }

$content = @(
    'Set shell = CreateObject("WScript.Shell")'
    'shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $StartScript + '""", 0, False'
) | Set-Content -LiteralPath $Vbs -Encoding Ascii

Write-Host "Created silent launcher: $Vbs" -ForegroundColor Green
Write-Host ""
Write-Host "Register the watchdog task with:" -ForegroundColor Cyan
Write-Host '  schtasks /Create /F /TN opencode-warp-watchdog /SC MINUTE /MO 5 /TR "wscript.exe "' + $Vbs + '""' -ForegroundColor White
