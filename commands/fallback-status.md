---
description: Show free-fallback system health (watcher, WARP, chain, rotations)
agent: build
---
Current free-fallback system status:

!`powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\yaleed\.config\opencode\warp-rotate\fallback-status.ps1`

Summarize the health of the free-fallback setup in plain language. Call out anything that needs action: watcher not running, WARP disconnected, stale models in the chain, or a burst of recent fallbacks.
