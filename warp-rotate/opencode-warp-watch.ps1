# opencode-warp-watch.ps1 - Watches opencode-fallback.log for model fallbacks
# (Big Pickle hitting the Zen free IP quota) and triggers a WARP IP rotation.
# Runs as an infinite loop (register via the HKCU Run key or a scheduled task).
# Mutex-guarded against duplicate instances.
param([int]$IntervalSeconds = 20)

$ErrorActionPreference = "Continue"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:USERPROFILE ".config\opencode"
$FallbackLog = Join-Path $ConfigDir "opencode-fallback.log"
$RotateScript = Join-Path $Dir "rotate-warp.ps1"
$WatchLog = Join-Path $Dir "watch.log"
$PosFile = Join-Path $Dir "watch-pos.txt"
$StateFile = Join-Path $Dir "last-rotation.json"
$TriggerPattern = "Auto-retrying with fallback model"
$MinRotateGapMinutes = 10

$MutexName = "Global\opencode-warp-watch"
$Mutex = $null
try { $Mutex = [System.Threading.Mutex]::new($false, $MutexName) } catch {}

$alreadyRunning = $false
if ($Mutex) {
    try { $alreadyRunning = -not $Mutex.WaitOne(0) } catch { $alreadyRunning = $true }
}
if ($alreadyRunning) {
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] another watcher instance already running - exiting" | Out-File -FilePath $WatchLog -Append -Encoding utf8
    exit 0
}

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Msg" | Out-File -FilePath $WatchLog -Append -Encoding utf8
}

function Read-NewLines([int]$LastPos) {
    if (-not (Test-Path $FallbackLog)) { return @(), 0 }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($FallbackLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = [int]$fs.Length
        if ($len -le $LastPos) { return @(), $len }
        $fs.Position = $LastPos
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $newText = $sr.ReadToEnd()
        return ($newText -split "`r?`n" | Where-Object { $_ -ne "" }), $len
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-LastRotate {
    if (-not (Test-Path $StateFile)) { return [DateTime]::MinValue }
    try {
        $j = Get-Content $StateFile -Raw | ConvertFrom-Json
        return [DateTime]::Parse($j.lastRotation)
    } catch { return [DateTime]::MinValue }
}

$lastPos = 0
if (Test-Path $PosFile) { $lastPos = [int](Get-Content $PosFile) }
if ($lastPos -lt 0) { $lastPos = 0 }

Write-Log "watcher started (interval=${IntervalSeconds}s)"

while ($true) {
    try {
        $lines, $newPos = Read-NewLines $lastPos
        if ($newPos -gt 0) { $lastPos = $newPos }

        $triggered = $false
        foreach ($line in $lines) {
            if ($line -like "*$TriggerPattern*") { $triggered = $true; break }
        }

        if ($triggered) {
            $lastRotate = Get-LastRotate
            $gap = (Get-Date) - $lastRotate
            if ($gap.TotalMinutes -ge $MinRotateGapMinutes) {
                # 1) Preferred: own VPS VPN (dedicated IP) - see vps-vpn/bootstrap.ps1
                $rotated = $false
                $vpsJson = Join-Path $Dir "vps-vpn.json"
                $flip = Join-Path $Dir "flip.ps1"
                if ((Test-Path $vpsJson) -and (Test-Path $flip)) {
                    try {
                        $vps = Get-Content $vpsJson -Raw | ConvertFrom-Json
                        if ($vps.Base -and $vps.Key) {
                            Write-Log "fallback detected - rotating VPS egress IP"
                            & $flip -Base $vps.Base -Key $vps.Key 2>&1 | ForEach-Object { Write-Log "  flip: $_" }
                            $rotated = $true
                        }
                    } catch {
                        Write-Log "VPS rotation error: $($_.Exception.Message)"
                    }
                }
                # 2) Fallback lane: WARP rotation (shared IPs, less reliable but automatic)
                if (-not $rotated) {
                    Write-Log "fallback detected in $FallbackLog - rotating WARP IP"
                    & $RotateScript -Reason "zen-fallback" 2>&1 | ForEach-Object { Write-Log "  rotate-warp: $_" }
                }
            } else {
                Write-Log "fallback detected but last rotation was $([math]::Round($gap.TotalMinutes))min ago (< $MinRotateGapMinutes) - skipping"
            }
        }

        try { Set-Content -Path $PosFile -Value $lastPos -NoNewline } catch {}
    } catch {
        Write-Log "watcher error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds $IntervalSeconds
}

if ($Mutex) {
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}
