# opencode-warp-start.ps1 - Ensures the WARP rotation watcher is always running.
# Used by BOTH the ONLOGON scheduled task AND the 5-minute watchdog task, so a dead
# watcher self-heals within minutes. Safe to run repeatedly (mutex-guarded watcher).
# 1) Best-effort: connect WARP (rotation only works when WARP is Connected).
# 2) Start opencode-warp-watch.ps1 hidden IF no watcher is holding the mutex.

$ErrorActionPreference = "Continue"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Watcher = Join-Path $Dir "opencode-warp-watch.ps1"
$LogFile = Join-Path $Dir "watchdog.log"
$Warp = "C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe"

function Write-Log([string]$Msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Msg" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Test-WatcherRunning {
    # If we can acquire the mutex, no watcher owns it -> watcher is NOT running.
    $mutex = $null
    try { $mutex = New-Object System.Threading.Mutex($false, 'Global\opencode-warp-watch') } catch { $mutex = $null }
    if ($mutex) {
        $acquired = $false
        try { $acquired = $mutex.WaitOne(0) } catch {}
        if ($acquired) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
        return -not $acquired
    }
    # Mutex creation failed - fall back to process scan (commandline match).
    return [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*opencode-warp-watch.ps1*" })
}

function Wait-WarpConnected([int]$MaxSeconds = 60) {
    # WARP's "happy eyeballs" handshake can take a while after a manual disconnect;
    # keep polling until status shows Connected instead of giving up after 3s.
    $elapsed = 0
    while ($elapsed -lt $MaxSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        if ((((& $Warp status 2>$null) -join " ")) -match "Connected") { return $true }
    }
    return $false
}

try {
    # 1) Ensure WARP is connected (self-heals if WARP dropped) - BUT only in WARP mode.
    #    In VPS mode (vps-vpn.json present) the WireGuard tunnel is the connection and
    #    re-connecting WARP would create a double tunnel.
    $vpsMode = Test-Path (Join-Path $Dir "vps-vpn.json")
    if ($vpsMode) {
        # nothing to do: tunnel handled by the WireGuard service
    } elseif (Test-Path $Warp) {
        $status = (& $Warp status 2>$null) -join " "
        if ($status -notmatch "Connected") {
            Write-Log "WARP not connected ($status) - attempting connect"
            & $Warp connect 2>$null | Out-Null
            if (Wait-WarpConnected 60) { Write-Log "WARP connected OK" }
            else { Write-Log "WARP still not connected after retry: $(((& $Warp status 2>$null) -join ' '))" }
        }
    } else {
        Write-Log "WARP not found at $Warp (rotation disabled)"
    }

    # 2) Start the watcher if it isn't running.
    if (-not (Test-WatcherRunning)) {
        Write-Log "watcher not running - starting opencode-warp-watch.ps1"
        Start-Process powershell.exe -ArgumentList @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", "`"$Watcher`""
        ) -WorkingDirectory $Dir -WindowStyle Hidden
        Start-Sleep -Seconds 2
        if (Test-WatcherRunning) { Write-Log "watcher started OK" }
        else { Write-Log "watcher start did not confirm - retry on next watchdog tick" }
    } else {
        Write-Log "watcher already running - nothing to do"
    }
} catch {
    Write-Log "start script error: $($_.Exception.Message)"
}

exit 0
