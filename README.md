# OpenCode Free Fallback + IP Rotation

Keep your OpenCode agent sessions alive **for free** — automatically switch to other free models when the Zen free quota runs out, and rotate your public IP via Cloudflare WARP so the free quota resets by itself.

Works with the free tier of **OpenCode Zen** (Big Pickle and friends) — no paid credits, no subscription, no credit card.

---

## The Problem

OpenCode Zen offers genuinely free models (`opencode/big-pickle`, `opencode/deepseek-v4-flash-free`, `opencode/mimo-v2.5-free`, …). But the free tier has a hidden catch:

- The free quota is **~50 requests per 5-hour rolling window**, enforced **per public IP**.
- **All Zen free models share that one IP quota.** When Big Pickle is exhausted, *every* `opencode/*-free` model fails with `Free usage exceeded` at the same time.
- Switching API keys / accounts does **not** reset it — it's your IP that's counted, not your account.

Result: long coding sessions die mid-task, and the only "official" advice is to add credits.

References: [opencode#15585](https://github.com/anomalyco/opencode/issues/15585), [opencode#28166](https://github.com/anomalyco/opencode/issues/28166).

## The Solution (2 layers, both free)

```
1) AUTO MODEL FALLBACK         2) AUTO IP ROTATION
   (fallback plugin)              (Cloudflare WARP watcher)

   big-pickle fails ──┬────────────► fallback chain continues
                      │              the session instantly on other
                      │              FREE models (Google AI Studio +
                      │              OpenRouter :free) — different
                      │              providers, independent quotas
                      │
                      └──► watcher sees the fallback event and
                           rotates WARP registration → new public IP
                           → Zen free quota resets → 5 min later the
                           plugin auto-switches back to big-pickle
```

| Layer | What | Quota | Cost |
|---|---|---|---|
| Zen free (`opencode/big-pickle` + `-free` models) | primary, best quality | ~50 req / 5h per IP | $0 |
| Google AI Studio (`google/gemini-*`) | fallback | ~1,500 req/day | $0 |
| OpenRouter `:free` models | fallback | 20 req/min, 50–1,000 req/day | $0 |
| Cloudflare WARP | IP rotation | unlimited | $0 |

## Verified Free Fallback Chain

All models below were **actually tested** against the fallback plugin (2026-08-04). Fallbacks are ordered best → lightest. Google and OpenRouter are independent of the Zen IP limiter; the trailing `opencode/*-free` models only help again once WARP has rotated the IP.

```jsonc
"fallback_models": [
  "google/gemini-3.6-flash",                    // Google AI Studio free tier
  "google/gemini-3.1-flash-lite",               // faster / lighter
  "openrouter/cohere/north-mini-code:free",     // 256K ctx, coding-tuned
  "openrouter/poolside/laguna-s-2.1:free",
  "openrouter/nvidia/nemotron-3-super-120b-a12b:free",
  "opencode/deepseek-v4-flash-free",            // Zen free (needs fresh IP)
  "opencode/mimo-v2.5-free",
  "opencode/laguna-s-2.1-free",
  "opencode/ling-3.0-flash-free",
  "opencode/north-mini-code-free",
  "opencode/nemotron-3-ultra-free"
]
```

More free options you can add (verify with `opencode models | grep free`):

```text
openrouter/openai/gpt-oss-20b:free
openrouter/nvidia/nemotron-3-ultra-550b-a55b:free
openrouter/google/gemma-4-26b-a4b-it:free
openrouter/poolside/laguna-xs-2.1:free
```

## Prerequisites (all free)

| Thing | Where | Why |
|---|---|---|
| OpenCode | https://opencode.ai | the agent itself |
| OpenCode Zen key | `opencode auth login` (free account) | Big Pickle |
| Google AI Studio key | https://aistudio.google.com/apikey → `opencode auth login` | Google fallbacks |
| OpenRouter key | https://openrouter.ai/keys → `opencode auth login` | OpenRouter fallbacks |
| Cloudflare WARP | https://one.one.one.one/ (free) | IP rotation |

> The Google and OpenRouter keys are optional but **recommended** — without them the chain is just Big Pickle → (dead Zen models until WARP rotates). With them, sessions survive even long outages.

## Quick Start — Windows

```powershell
git clone https://github.com/yaleedhaque/opencode-free-fallback.git
cd opencode-free-fallback
.\setup-windows.ps1
```

Or do it manually:

```powershell
# 1. Install the fallback plugin (global config)
opencode plugin opencode-runtime-fallback -g

# 2. Copy the chain config
copy opencode-fallback.jsonc "$env:USERPROFILE\.config\opencode\opencode-fallback.jsonc"

# 3. Point opencode at big-pickle + the plugin (opencode.jsonc)
#    {"model": "opencode/big-pickle", "plugin": ["opencode-runtime-fallback"]}

# 4. Install the WARP watcher scripts + auto-start
copy warp-rotate\rotate-warp.ps1 "$env:USERPROFILE\.config\opencode\warp-rotate\"
copy warp-rotate\opencode-warp-watch.ps1 "$env:USERPROFILE\.config\opencode\warp-rotate\"
# add to HKCU\...\Run  or  schtasks /Create /SC ONLOGON /TN opencode-warp-rotate /TR powershell...
Start-Process powershell -ArgumentList '-File', '"<your>\.config\opencode\warp-rotate\opencode-warp-watch.ps1"'

# 5. Connect WARP once (needed for rotation)
"C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" connect
```

## Quick Start — Linux / macOS

```bash
# 1. Install plugin + config (same as Windows, paths under ~/.config/opencode)
opencode plugin opencode-runtime-fallback -g
cp opencode-fallback.jsonc ~/.config/opencode/opencode-fallback.jsonc
# opencode.jsonc: {"model": "opencode/big-pickle", "plugin": ["opencode-runtime-fallback"]}

# 2. WARP CLI (see https://developers.cloudflare.com/cloudflare-one/connections/connect-devices/warp)
chmod +x warp-rotate/rotate-warp.sh warp-rotate/opencode-warp-watch.sh
# 3. Run the watcher as a background service:
nohup ./warp-rotate/opencode-warp-watch.sh 20 &
#   or a systemd user unit / launchd plist / cron @reboot
```

## How It Works

1. **Fallback plugin** (`opencode-runtime-fallback`) listens for message errors. When Big Pickle returns a 429 / `Free usage exceeded`, it aborts the turn and replays it on the next model in `fallback_models`.
2. Models that fail enter a **5-minute cooldown**; the plugin tries the next one. Google/OpenRouter free tiers are separate accounts/IPs, so they keep working.
3. **WARP watcher** polls `~/.config/opencode/opencode-fallback.log` every 20s. When it sees `Auto-retrying with fallback model` (the plugin's dispatch log), it runs `rotate-warp.ps1/.sh`:
   `warp-cli disconnect → registration delete → registration new → connect → verify IP changed`.
4. The new public IP gives Big Pickle a fresh ~50-request / 5h window. When its 5-minute cooldown expires, the plugin **auto-recovers** to Big Pickle and your normal workflow resumes.

## Config Reference

### `opencode.jsonc`

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/big-pickle",
  "plugin": ["opencode-runtime-fallback"]
}
```

### `opencode-fallback.jsonc` (plugin config)

| Key | Value | Meaning |
|---|---|---|
| `retry_on_errors` | `[429,500,502,503,504]` | trigger fallback on these HTTP codes |
| `retryable_error_patterns` | `["free usage", ...]` | trigger on Zen's text errors too |
| `max_fallback_attempts` | `12` | how many models to try |
| `cooldown_seconds` | `300` | retry big-pickle after 5 min (IP is rotated by then) |
| `timeout_seconds` | `90` | give up on a slow fallback and move on |
| `notify_on_fallback` | `true` | toast on switch |

## Alternative Plugins (researched 2026-08)

The fallback plugin choice is yours; the chain + WARP scripts work with any of them. Comparison of what's out there:

| Plugin | Stars | Notes |
|---|---|---|
| [`opencode-runtime-fallback`](https://github.com/youngbinkim0/opencode-fallback) | — | **used here**; per-agent/global chains, cooldown + auto-recovery, custom error patterns, logs `Auto-retrying with fallback model` (what the WARP watcher greps for) |
| [`opencode-rate-limit-fallback`](https://github.com/liamvinberg/opencode-rate-limit-fallback) | 26 | simpler; `rate-limit-fallback.json`, cooldown only |
| [`opencode-auto-fallback`](https://github.com/HyeokjaeLee/opencode-auto-fallback) | 7 | most advanced: structured SDK error classification, backoff retry, large-context fallback |
| [`opencode-rate-limit`](https://github.com/zaplakhov/opencode-rate-limit) | — | priority pool + `/rate-limit-status` report |

> None of them solve the **per-IP Zen free quota** by themselves — that's what the WARP rotation layer adds.

## Troubleshooting

- **"No models tried / all failed"** → check you added the Google + OpenRouter keys (`opencode auth login`), then `opencode models | grep -E "free|gemini"`.
- **Watcher not rotating** → confirm `warp-cli status` says `Connected`; logs at `~/.config/opencode/warp-rotate/watch.log` and `warp-rotate.log`.
- **IP didn't change** → WARP sometimes reissues the same address; the script retries 3×. Wait ~10 min and rotate again.
- **WARP IPs are shared** → a fresh WARP address may occasionally arrive already quota-burned by another Zen free user. The fallback chain still keeps your session alive; the next rotation usually lands a clean one.
- **Free model quota resets** → Zen's ~50 req / 5h window resets on its own; the WARP rotation just makes you reach it sooner.

## Honest Caveats

- All Zen free models are "for a limited time" while OpenCode collects feedback. The chain is designed to be edited as models come and go.
- Free tiers are rate-limited by design. For heavy production use, add a cheap paid fallback (e.g. `opencode/deepseek-v4-flash`) instead of fighting quotas.
- Rotating your public IP is against the *spirit* of the free tier. It works, but use it like a reasonable person: as a safety net, not to farm unlimited free compute.
- Google's free tier is the most generous (≈1,500 req/day). OpenRouter's free tier caps at 50 req/day unless you've ever bought $10 of credits (one-time, never expires → 1,000 req/day).

## License

[MIT](LICENSE)
