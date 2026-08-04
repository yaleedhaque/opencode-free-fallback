#!/usr/bin/env bash
# rotate-warp.sh - Rotate Cloudflare WARP registration to obtain a new public IP.
# Linux/macOS equivalent of warp-rotate/rotate-warp.ps1.
# Requires: warp-cli (sudo) or the WARP GUI client.
set -u

WARP="${WARP_CLI:-warp-cli}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$DIR/warp-rotate.log"
STATE="$DIR/last-rotation.json"
REASON="${1:-manual}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }

pubip() {
  curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace | grep '^ip=' | cut -d= -f2
}

warp_status() { "$WARP" status 2>/dev/null | tr '\n' ' '; }

log "[$REASON] rotation started (status=$(warp_status))"
command -v "$WARP" >/dev/null 2>&1 || { log "[$REASON] ERROR: warp-cli not found"; exit 1; }

BEFORE="$(pubip)"
log "[$REASON] current public IP: $BEFORE"

NEW="$BEFORE"
ATTEMPT=0
CONNECTED=false

while [ "$ATTEMPT" -lt 3 ] && [ "$NEW" = "$BEFORE" ]; do
  ATTEMPT=$((ATTEMPT+1))
  log "[$REASON] rotation attempt $ATTEMPT/3"
  if warp_status | grep -q Connected; then "$WARP" disconnect >/dev/null 2>&1; fi
  sleep 2
  sudo -n "$WARP" registration delete >/dev/null 2>&1 || "$WARP" registration delete >/dev/null 2>&1
  sleep 1
  sudo -n "$WARP" registration new >/dev/null 2>&1 || "$WARP" registration new >/dev/null 2>&1
  sleep 2
  "$WARP" connect >/dev/null 2>&1
  for i in $(seq 1 30); do
    sleep 2
    if warp_status | grep -q Connected; then CONNECTED=true; break; fi
  done
  sleep 3
  NEW="$(pubip)"
  log "[$REASON] attempt $ATTEMPT: connected=$CONNECTED new IP=$NEW"
done

if [ "$CONNECTED" != true ]; then
  log "[$REASON] FAILED: WARP did not reach Connected state after rotation"
  exit 1
fi

if [ -n "$NEW" ] && [ "$NEW" != "$BEFORE" ]; then
  log "[$REASON] SUCCESS: IP rotated $BEFORE -> $NEW"
else
  log "[$REASON] WARNING: IP unchanged ($BEFORE) after $ATTEMPT attempt(s)"
fi

echo "{\"lastRotation\":\"$(date -Is)\",\"before\":\"$BEFORE\",\"after\":\"$NEW\",\"reason\":\"$REASON\"}" > "$STATE"
exit 0
