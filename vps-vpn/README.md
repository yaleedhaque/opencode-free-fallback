# Your Own Free VPN for OpenCode (option B) — dedicated IP + rotation

Replaces Cloudflare WARP with a **dedicated public IP that only you burn**. Big Pickle gets
the full ~50 req / 5h Zen window every time (no shared-WARP-IP lottery), and a one-command
flip swaps your outbound IP when the quota runs out. Total cost: **$0** (Oracle always-free VM).

```
Windows (WireGuard client, full tunnel)
   │  udp 51820  │
   ▼             ▼
Oracle free Ubuntu VM ── egress via dedicated public IP ──► api.opencode.ai / zen
   │
   HTTP :8099/rotate?key=...  ← flip.ps1 (Windows) calls this to rotate egress IP
```

## Cost breakdown

| Item | Cost | Notes |
|---|---|---|
| Oracle Cloud free tier VM (Ampere A1, 1–4 OCPU) | $0 | Always Free, no card needed beyond verification |
| WireGuard (server + Windows client) | $0 | open source |
| Egress | ~10 TB/mo free on OCI | more than enough |

## Part 1 — Create the free VM (Oracle Cloud, ~15 min)

1. Go to **https://signup.oraclecloud.com** and create an account
   (free tier — a card is requested for identity verification only; nothing is charged).
   Your **home region** is fixed at signup — the free VM must live there.
2. Console → **Compute → Instances → Create instance**.
3. Name: `opencode-vpn`. Image: **Canonical Ubuntu 24.04** (always-free eligible).
4. Shape: click **Change shape** → enable **"Always Free eligible"** filter →
   pick **Ampere A1** (1 OCPU / 6 GB RAM is plenty and free) or **VM.Standard.E2.1.Micro**.
5. Networking: keep the default VCN/subnet, **"Assign a public IPv4 address" = yes**.
6. SSH keys: click **"Generate a key pair for me"** → download both keys and save them
   (the `.key` is your private key; you'll use it for SSH).
7. **Create instance**, wait for status **Running**.
8. Open **Networking → Security Lists → default → Add Ingress Rules**:
   - UDP, port `51820`, source `0.0.0.0/0` (WireGuard)
   - TCP, port `22`, source `0.0.0.0/0` (SSH; already present usually)
   - TCP, port `8099`, source **your home public IP/32** only (rotation trigger —
     find your IP at https://1.1.1.1/cdn-cgi/trace or just use `0.0.0.0/0` to start)

## Part 2 — Install the server (the VM does everything, ~2 min)

SSH into the VM (from your Windows PowerShell), then run the bootstrap script:

```powershell
# Windows, one-time: get your private key path ready, e.g.
ssh -i "$env:USERPROFILE\Downloads\ssh-key-YYYY-MM-DD.key" ubuntu@<VM-IP>
```

Inside the VM shell, run the setup (download it from this repo):

```bash
cd /tmp
curl -L -o vps-setup.sh https://raw.githubusercontent.com/yaleedhaque/opencode-free-fallback/main/vps-vpn/vps-setup.sh
chmod +x vps-setup.sh
./vps-setup.sh
```

When it finishes it prints **your Windows WireGuard config**, plus:

```
EGRESS_ROTATE_URL=http://<VM-IP>:8099/rotate
EGRESS_ROTATE_KEY=<secret>
```

**Copy those three things (client config + URL + key) somewhere safe.**

> It also saved the config to `~/client.conf` on the VM if you prefer to `scp` it down:
> `scp -i <key> ubuntu@<VM-IP>:client.conf C:\Users\<you>\client.conf`

## Part 3 — Let the script do everything (~3 min)

From your Windows machine, one command:

```powershell
cd opencode-free-fallback
powershell -ExecutionPolicy Bypass -File vps-vpn\bootstrap.ps1
```

It will ask for: your **VM IP**, the SSH **username** (default `ubuntu`), and the path to
your **downloaded SSH key** (it auto-finds one in `Downloads`). Then it automates all of it:

1. SSHes in and runs `vps-setup.sh` (installs WireGuard server, sets up rotation).
2. Pulls back your client config + rotation credentials.
3. Installs WireGuard for Windows (free) via winget.
4. Enables the tunnel as a Windows **service** — auto-starts at boot, no clicks needed.
5. **Disables WARP** for you (so there's no double tunnel).
6. Writes the rotation config so the watcher **auto-rotates your VPS IP** on fallback.

You can also run the whole thing via the main wizard: `setup-windows.ps1` → choose **(A) Own VPN**.

### Managing the tunnel day to day

| Action | Command |
|---|---|
| Turn VPN on | `powershell -File vps-vpn\connect-vps.ps1` |
| Turn VPN off (back to normal internet) | `powershell -File vps-vpn\disconnect-vps.ps1` |
| Rotate IP now | `powershell -File vps-vpn\flip.ps1 -Base "<EGRESS_ROTATE_URL>" -Key "<KEY>"` |

All three are automatic in normal use — these are only for when you want to override.

## Part 4 — Rotate the IP when the quota runs out

Nothing to do — it's automatic. When the fallback plugin logs `Auto-retrying with
fallback model`, the watcher calls `flip.ps1` with your saved config, the VM SNATs to its
next address → new public IP → Zen window resets → Big Pickle returns after its 5-min
cooldown. Google/OpenRouter lanes carry the session meanwhile.

If WARP is still installed, the watcher uses it as a **backup** only when the VPS flip fails.

### Rotating between MORE IPs (optional, free)

For rotation to pick a *different* IP, the VM needs 2+ addresses:

1. OCI console → **Networking → VCN → your subnet → IP Management → Create IPv4**:
   add 2–3 reserved public IPs.
2. **Attach** them: instance → **Attached VNICs → your VNIC → Add Secondary Private IP**
   → check "Assign a public IP" → pick the reserved ones. OCI auto-configures them
   on the interface (verify on the VM: `ip -4 addr show`).
3. `rotate-egress.sh` already cycles through all of them — just hit flip.ps1 again.

## Verify it all works

- [ ] `warp-cli status` → Disconnected (WARP off)
- [ ] `curl https://1.1.1.1/cdn-cgi/trace` → `ip=` matches the VM's IP
- [ ] `.\flip.ps1 ...` → prints a new IP
- [ ] opencode uses big-pickle normally; `/fallback-status` still works

## Caveats

- Full tunnel = **all** your traffic (browser, gh, etc.) egresses from a datacenter IP.
  Some sites block datacenter ranges (banks, some logins). If that bites, keep WARP or
  a normal connection for those apps, or use a per-app proxy instead of full tunnel.
- Rotating to dodge the Zen free quota is against its *spirit* — use it as a safety net,
  not to farm unlimited free compute (same rule as the WARP layer).
- Oracle "always free" requires the VM in your **home region**; free resources are
  limited to one region.
- Don't touch the instance's **primary** public IP after WireGuard works or SSH may drop.
  Use flip.ps1 / secondary IPs for rotation, never the primary.
