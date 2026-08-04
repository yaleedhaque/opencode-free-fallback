#!/usr/bin/env bash
# opencode-warp-watch.sh - Linux/macOS equivalent of opencode-warp-watch.ps1.
# Watches ~/.config/opencode/opencode-fallback.log for fallback events and
# triggers a WARP IP rotation (see rotate-warp.sh).
# Run as a background service: systemd user unit, launchd, cron @reboot, or a nohup loop.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FALLBACK_LOG="${FALLBACK_LOG:-$HOME/.config/opencode/opencode-fallback.log}"
ROTATE="$DIR/rotate-warp.sh"
WATCH_LOG="$DIR/watch.log"
POS_FILE="$DIR/watch-pos.txt"
STATE_FILE="$DIR/last-rotation.json"
TRIGGER="Auto-retrying with fallback model"
MIN_GAP_MINUTES=10
INTERVAL="${1:-20}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$WATCH_LOG"; }

# Mutex via flock on the state dir
exec 9>"$DIR/.watch.lock"
if ! flock -n 9; then
  log "another watcher instance already running - exiting"
  exit 0
fi

last_pos=0
[ -f "$POS_FILE" ] && last_pos=$(cat "$POS_FILE" 2>/dev/null || echo 0)
last_pos=$((last_pos<0 ? 0 : last_pos))

log "watcher started (interval=${INTERVAL}s)"

while true; do
  if [ -f "$FALLBACK_LOG" ]; then
    size=$(wc -c < "$FALLBACK_LOG")
    if [ "$size" -gt "$last_pos" ]; then
      tail -c +$((last_pos+1)) "$FALLBACK_LOG" | while IFS= read -r line; do
        case "$line" in
          *"$TRIGGER"*)
            if [ -f "$STATE_FILE" ]; then
              last_rotate=$(grep -o '"lastRotation":"[^"]*"' "$STATE_FILE" | cut -d'"' -f4)
              last_epoch=$(date -d "$last_rotate" +%s 2>/dev/null || echo 0)
            else
              last_epoch=0
            fi
            now_epoch=$(date +%s)
            gap_min=$(( (now_epoch - last_epoch) / 60 ))
            if [ "$gap_min" -ge "$MIN_GAP_MINUTES" ]; then
              log "fallback detected in $FALLBACK_LOG - rotating WARP IP"
              "$ROTATE" zen-fallback >> "$WATCH_LOG" 2>&1
            else
              log "fallback detected but last rotation was ${gap_min}min ago (< $MIN_GAP_MINUTES) - skipping"
            fi
            ;;
        esac
      done
      last_pos=$size
      echo "$last_pos" > "$POS_FILE"
    fi
  fi
  sleep "$INTERVAL"
done
