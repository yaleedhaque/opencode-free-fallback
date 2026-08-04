#!/usr/bin/env bash
# vps-setup.sh - One-shot bootstrap for the "own VPN" OpenCode egress.
# Run on the Oracle always-free Ubuntu VM (as the default 'ubuntu' user, it will sudo).
#   - Installs WireGuard server, full-tunnel peer (routes ALL client traffic via this VM)
#   - Enables outbound IP rotation: cycles the egress source IP among the private IPs
#     attached to this instance (add them in the OCI console, optional but recommended)
#   - Starts a tiny HTTP trigger (port 8099) so the Windows side can flip the IP on demand
#   - Prints the Windows client config at the end - save it as your .conf
set -euo pipefail

LOG=/tmp/vps-setup.log
exec > >(tee -a "$LOG") 2>&1
echo "== vps-setup started $(date) =="

# --- 0. Detect main interface + distro -----------------------------------
IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
[ -z "$IFACE" ] && { echo "ERROR: no default route / interface found"; exit 1; }
echo "Main interface: $IFACE"
PRIV=$(ip -o -4 addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)
echo "Private IP: $PRIV"

sudo apt-get update -y -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard wireguard-tools python3 iptables curl >/dev/null

# --- 1. Server keys -------------------------------------------------------
sudo mkdir -p /etc/wireguard
cd /etc/wireguard
sudo test -f server.key || { wg genkey | sudo tee server.key >/dev/null; }
sudo test -f client.key || { wg genkey | sudo tee client.key >/dev/null; }
SERVER_PRIV=$(sudo cat server.key)
SERVER_PUB=$(sudo sh -c 'cat server.key | wg pubkey')
CLIENT_PRIV=$(sudo cat client.key)
CLIENT_PUB=$(sudo sh -c 'cat client.key | wg pubkey')

# --- 2. sysctl forward ----------------------------------------------------
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-wg.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-wg.conf >/dev/null

# --- 3. wg0 server config -------------------------------------------------
WG_NET="10.66.0.0/24"
sudo tee /etc/wireguard/wg0.conf >/dev/null <<EOF
[Interface]
Address = 10.66.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV
PostUp = iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.66.0.2/32
EOF

sudo systemctl enable wg-quick@wg0 >/dev/null
sudo systemctl restart wg-quick@wg0
sudo systemctl start wg-quick@wg0 2>/dev/null || true
echo "WireGuard server up: $(sudo wg show wg0 2>/dev/null | head -n3)"

# --- 4. Egress rotation script --------------------------------------------
# Cycles the SNAT source IP across the private IPs attached to this instance
# (the OCI cloud NAT maps each private IP to ITS own public IP).
sudo tee /usr/local/bin/rotate-egress.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# rotate-egress.sh - flip the outbound public IP of this VM to the next attached one.
IFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
[ -z "$IFACE" ] && { echo "no iface"; exit 1; }

# All private IPv4s on the interface, in order; we keep the FIRST as primary
# (used by default) and cycle among ALL of them so flips always land somewhere.
MAPS=($(ip -o -4 addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1))
[ "${#MAPS[@]}" -eq 0 ] && { echo "no addresses"; exit 1; }

STATE=/var/lib/egress-index
IDX=0
[ -f "$STATE" ] && IDX=$(cat "$STATE")
IDX=$(( (IDX + 1) % ${#MAPS[@]} ))
echo "$IDX" > "$STATE"
TARGET="${MAPS[$IDX]}"

iptables -t nat -F POSTROUTING
iptables -t nat -A POSTROUTING -o "$IFACE" -j SNAT --to-source "$TARGET"

# force existing tunnels/connections to rebuild with the new source
ip route flush cache 2>/dev/null || true

echo "egress now SNAT -> $TARGET"
curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep '^ip='
EOF
sudo chmod +x /usr/local/bin/rotate-egress.sh

# --- 5. HTTP trigger (flip on demand) -------------------------------------
# GET http://<vm>:8099/rotate?key=<KEY>  -> rotates egress, returns new public IP.
EGRESS_KEY=$(sudo sh -c "head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20")
sudo tee /usr/local/bin/egress-server.py >/dev/null <<EOF
import http.server, subprocess, urllib.parse, os
KEY = "$EGRESS_KEY"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == "/rotate" and urllib.parse.parse_qs(p.query).get("key", [""])[0] == KEY:
            out = subprocess.run(["/usr/local/bin/rotate-egress.sh"], capture_output=True, text=True, timeout=30).stdout
            body = out.encode()
            self.send_response(200)
        else:
            body = b"nope"
            self.send_response(404)
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 8099), H).serve_forever()
EOF

sudo tee /etc/systemd/system/egress-rotate.service >/dev/null <<EOF
[Unit]
Description=egress rotation HTTP trigger
After=network.target
[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/egress-server.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable egress-rotate >/dev/null
sudo systemctl restart egress-rotate

# --- 6. UFW (allow wireguard + trigger only) ------------------------------
if command -v ufw >/dev/null; then
    sudo ufw allow 51820/udp >/dev/null 2>&1 || true
    sudo ufw allow 8099/tcp >/dev/null 2>&1 || true
    sudo ufw allow OpenSSH >/dev/null 2>&1 || true
    sudo ufw --force enable >/dev/null 2>&1 || true
fi

# --- 7. Print client config + secrets -------------------------------------
PUBIP=$(curl -s --max-time 10 https://1.1.1.1/cdn-cgi/trace | grep '^ip=' | cut -d= -f2)
echo ""
echo "==================================================================="
echo " SAVE THESE (Windows client config) - also written to ~/client.conf"
echo "==================================================================="
cat <<EOF

[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.66.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $PUBIP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
sudo sh -c "cat > /home/ubuntu/client.conf <<'EOC'
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.66.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $PUBIP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOC"
chmod 600 /home/ubuntu/client.conf

echo ""
echo "EGRESS_ROTATE_URL=http://$PUBIP:8099/rotate"
echo "EGRESS_ROTATE_KEY=$EGRESS_KEY"
echo "  (add $PUBIP to the OCI security list on TCP 8099, from your home IP only)"
echo "==================================================================="
echo "SSH is still on your ONLY original public IP. DO NOT change the instance's"
echo "primary public IP until WireGuard is working, or you lose SSH."

# Machine-readable file for vps-vpn/bootstrap.ps1 on Windows:
cat > /home/ubuntu/vps-info.txt <<EOF
EGRESS_ROTATE_URL=http://$PUBIP:8099/rotate
EGRESS_ROTATE_KEY=$EGRESS_KEY
SERVER_PUBLIC_KEY=$SERVER_PUB
EOF
chmod 600 /home/ubuntu/vps-info.txt
echo "info written to ~/vps-info.txt"
