# OpenCode Free Fallback + IP Rotation

Keep your OpenCode agent sessions alive **for free** — automatically switch to other free models when the Zen free quota runs out, and rotate your public IP via Cloudflare WARP so the free quota resets by itself.

Works with the free tier of **OpenCode Zen** (Big Pickle and friends) — no paid credits, no subscription, no credit card.

---

## Daily life — nothing to do

Once installed, everything is automatic. You just use opencode normally.

| Situation | What happens (automatic) |
|---|---|
| Big Pickle hits its ~50 req / 5h limit mid-session | Session switches to the free chain (Google → OpenRouter) instantly |
| IP quota is exhausted | Watcher rotates your IP (own VPN first, WARP as backup) within seconds |
| WARP/VPN drops | Watcher reconnects it within ~20 s (no more waiting 5 minutes) |
| PC reboots | Watcher + tunnel auto-start at logon |
| You `git push` | Works normally — no need to touch WARP |

Manual tools (only when you want control):
- **Health check:** `/fallback-status` inside opencode (or `fallback-status.ps1`)
- **Rotate IP now:** `powershell -File <config>\warp-rotate\flip.ps1 -Base ... -Key ...`
- **Turn VPN off/on:** `connect-vps.ps1` / `disconnect-vps.ps1` (own-VPN mode)
- **Check model list freshness:** `verify-chain.ps1`

> **If a message errors and opencode waits at a prompt:** press `Esc` then type `continue` —
> the plugin will retry the turn on the fallback chain. With the fixes above this should
> be rare; it happens when the IP was mid-rotation during your exact request.

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
  "openrouter/openai/gpt-oss-20b:free",
  "openrouter/google/gemma-4-31b-it:free",
  "openrouter/google/gemma-4-26b-a4b-it:free",
  "openrouter/inclusionai/ling-3.0-flash:free",
  "openrouter/poolside/laguna-xs-2.1:free",
  "openrouter/nvidia/nemotron-3-ultra-550b-a55b:free",
  "openrouter/nvidia/nemotron-3-nano-30b-a3b:free",
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

**One command. It does everything.**

```powershell
git clone https://github.com/yaleedhaque/opencode-free-fallback.git
cd opencode-free-fallback
powershell -ExecutionPolicy Bypass -File setup-windows.ps1
```

It asks one question — which IP-rotation method:

- **(A) Own VPN (recommended)** — guided setup of a free Oracle Cloud VM + WireGuard:
  a **dedicated** public IP that only you burn, so Big Pickle reliably gets its full
  ~50 req / 5h window (no shared-IP lottery like WARP). Rotation is automatic.
- **(B) Cloudflare WARP** — quick, shared IPs; auto-installs WARP for you if missing.
- **(C) None** — just the fallback chain (Google / OpenRouter carry your sessions).

Whichever you pick, it installs the plugin, chain config, watcher (autostart at logon),
self-healing watchdog, and `/fallback-status` — then you're done.

Or do it manually (for reference):

```powershell
# 1. Install the fallback plugin (global config)
opencode plugin opencode-runtime-fallback -g

# 2. Copy the chain config
copy opencode-fallback.jsonc "$env:USERPROFILE\.config\opencode\opencode-fallback.jsonc"

# 3. Point opencode at big-pickle + the plugin (opencode.jsonc)
#    {"model": "opencode/big-pickle", "plugin": ["opencode-runtime-fallback"]}

# 3b. Install WARP automatically (download + silent install + register + connect):
powershell -File warp-rotate\install-warp.ps1

# 4. Install the WARP watcher scripts + auto-start + self-healing watchdog
copy warp-rotate\*.ps1 "$env:USERPROFILE\.config\opencode\warp-rotate\"
copy commands\fallback-status.md "$env:USERPROFILE\.config\opencode\commands\"
# instant start at logon (no admin):
#   add to HKCU\...\Run -> powershell -File "<config>\warp-rotate\opencode-warp-start.ps1"
# self-healing (restarts the watcher if it dies every 5 min):
schtasks /Create /F /TN opencode-warp-watchdog /SC MINUTE /MO 5 /TR "powershell.exe -File <config>\warp-rotate\opencode-warp-start.ps1"
Start-Process powershell -ArgumentList '-File', '"<your>\.config\opencode\warp-rotate\opencode-warp-start.ps1"'

# 5. Done - install-warp.ps1 already connected WARP. Verify:
"C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe" status   # -> Connected
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
  // Chores (title gen, compaction summaries) run on Google's separate ~1500/day
  // free quota instead of burning Zen's ~50 req / 5h window.
  "small_model": "google/gemini-3.1-flash-lite",
  "plugin": ["opencode-runtime-fallback"],
  // Prune stale tool output at compaction -> fewer tokens per request ->
  // more requests fit inside each quota window.
  "compaction": {
    "auto": true,
    "prune": true,
    "reserved": 10000
  }
}
```

### `opencode-fallback.jsonc` (plugin config)

| Key | Value | Meaning |
|---|---|---|
| `retry_on_errors` | `[429,500,502,503,504]` | trigger fallback on these HTTP codes |
| `retryable_error_patterns` | `["free usage", "rate limit", "FreeUsageLimitError", ...]` | trigger on text errors too (Zen + OpenRouter/Google phrasings) |
| `max_fallback_attempts` | `20` | how many models to try |
| `cooldown_seconds` | `300` | retry big-pickle after 5 min (IP is rotated by then) |
| `timeout_seconds` | `90` | give up on a slow fallback and move on |
| `notify_on_fallback` | `true` | toast on switch |

## Self-healing WARP watcher

The watcher no longer relies on a single process that can silently die. It is now:

1. **Started at logon** via the HKCU Run key (`opencode-warp-rotate`) — instant, no admin needed.
2. **Watchdogged** by a scheduled task (`opencode-warp-watchdog`, every 5 min) that runs `opencode-warp-start.ps1`: if the watcher holds no mutex, it relaunches it hidden; it also re-connects WARP if it dropped. A dead watcher self-heals within minutes.
3. Runs the same mutex-guarded loop as before (no duplicate instances).

## Observability

- **`/fallback-status`** (installed as a global command): one-shot health report — opencode version, primary/small models, chain size, WARP status + public IP, watcher PID, last IP rotation, recent fallback events.
- **`verify-chain.ps1`** (in `warp-rotate/`): the Zen/OpenRouter free lists rotate monthly; this diffs your chain against `opencode models` and flags (a) stale chain models and (b) new free models worth adding. Run manually or schedule weekly:
  `schtasks /Create /TN opencode-chain-verify /SC WEEKLY /D FRI /ST 09:00 /TR "powershell -File ...\warp-rotate\verify-chain.ps1"`

## Adding free provider lanes (optional but recommended)

Each provider below has its own independent free quota, so the more you add, the fewer fallbacks land on shared lanes. All are free / no credit card:

| Provider | Get key | Free quota | Add to chain (after `opencode auth login`) |
|---|---|---|---|
| Google AI Studio | https://aistudio.google.com/apikey | ~1,500 req/day | already lane #1 |
| OpenRouter | https://openrouter.ai/keys | 50 req/day; **1,000 req/day after a one-time $10 top-up** (never expires) | already lanes #3–12 |
| Groq | https://console.groq.com/keys | ~1K–14.4K req/day | `groq/gpt-oss-20b` |
| Cerebras | https://cloud.cerebras.ai | 30 RPM, 1M tokens/day | `cerebras/qwen3-235b-a22b` |
| NVIDIA NIM | https://build.nvidia.com | ~40 RPM, no card | `nvidia/glm-5.1`, `nvidia/kimi-k2.6` |
| GitHub Copilot free | already authed on most machines | 50 premium req/month | `copilot/<model>` (depends on plan exposed by opencode) |

> **Verified dead ends (2026-08-04):** `opencode-go/*` requires a payment method on this account; the `kimi-for-coding/*` key was expired. Re-test before adding either. The un-commented block at the bottom of `opencode-fallback.jsonc` shows exactly where each new lane goes.

> **Best single capacity lever:** one-time $10 on OpenRouter permanently raises `:free` limits from 50 → 1,000 req/day (20×). If you ever pay anything for this hobby, spend it there first.

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
- **`git push` used to fail with "curl 52 Empty reply" over WARP** → fixed: `git config --global http.version HTTP/1.1` (pushes now work with WARP connected — no more disconnecting).
- **Watcher not rotating** → confirm `warp-cli status` says `Connected`; logs at `~/.config/opencode/warp-rotate/watch.log` and `warp-rotate.log`.
- **WARP manually disconnected → Zen limit instantly reached** → the moment you disconnect, your real ISP IP (already quota-burned) is exposed, so Big Pickle fails again. `rotate-warp.ps1` now self-heals: if WARP is not `Connected` when a rotation is requested, it reconnects WARP first (waiting through the "happy eyeballs" handshake), then rotates — a fresh WARP IP resets the Zen window. The watchdog (`opencode-warp-start.ps1`) also now waits up to 60s for `Connected` instead of giving up after 3s. If you want WARP off for a while, expect Big Pickle to stay dead until it's back; the Google/OpenRouter lanes still carry the session.
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
