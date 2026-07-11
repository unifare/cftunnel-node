#!/usr/bin/env bash
# sing-box all-in-one proxy + CF Tunnel
# Protocols: VLESS+XHTTP(tunnel), VLESS+WS(tunnel), Hysteria2(direct), TUIC(direct), Reality(direct)
set -euo pipefail
D=/opt/proxy
K=""; xh=""; sh=""; xp=20001; sp=20002; hp=8443; tp=8444; rp=8445; tn=""; REALITY_SNI="swift.com"; FRESH=0

while test $# -gt 0; do
  case "$1" in
    --tok)          shift; K="$1" ;;
    --xray-host)    shift; xh="$1" ;;
    --sb-host)      shift; sh="$1" ;;
    --reality-sni)  shift; REALITY_SNI="$1" ;;
    --tunnel-name)  shift; tn="$1" ;;
    --fresh)        FRESH=1; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done
test -z "${K}" && {
  # No token: show current deployment status if exists
  if test -f "$D/.state"; then
    . "$D/.state"
    . "$D/sb_keys.env" 2>/dev/null || true
    echo "=== Current Deployment ==="
    echo "  Zone:     $zone_name"
    echo "  Tunnel:   $tunnel_name ($tunnel_id)"
    echo "  IP:       ${public_ip:-unknown}"
    echo ""
    echo "  Tunnel hosts:"
    echo "    XHTTP:  $(echo $hosts | cut -d, -f1):443"
    echo "    WS:     $(echo $hosts | cut -d, -f2):443"
    echo ""
    echo "  Direct ports:"
    echo "    HY2:     ${public_ip:-IP}:8443"
    echo "    TUIC:    ${public_ip:-IP}:8444"
    echo "    Reality: ${public_ip:-IP}:8445"
    echo ""
    if test -f "$D/clients.txt"; then
      echo "=== Client Links ==="
      cat "$D/clients.txt"
    fi
    echo ""
    echo "=== Commands ==="
    echo "  Update:  sudo bash $0 --tok <TOKEN>"
    echo "  Rebuild: sudo bash $0 --tok <TOKEN> --fresh"
    echo "  Uninstall: sudo bash $D/scripts/uninstall.sh"
    if test -n "${public_ip:-}"; then
      echo ""
      echo "=== Subscription ==="
      echo "  v2ray:  http://${public_ip}:9091/sub"
      echo "  clash:  http://${public_ip}:9091/clash"
    fi
    exit 0
  fi
  echo "Usage: sudo bash install.sh --tok <CF_API_TOKEN>"
  echo "       sudo bash install.sh            (show status)"
  exit 1
}
test "$EUID" -ne 0 && { echo "Run as root"; exit 1; }
apt-get update -qq && apt-get install -y -qq jq curl unzip 2>/dev/null

# Get public IP
PUBLIC_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb 2>/dev/null || echo "unknown")

printf "%s" "$K" > /tmp/_cftok_val; chmod 600 /tmp/_cftok_val
trap 'rm -f /tmp/_cftok_val /tmp/_cf.py /tmp/_err' EXIT

cat > /tmp/_cf.py << 'PYHELPER'
import sys, json, urllib.request
tok_val = open('/tmp/_cftok_val').read().strip()
prefix = 'Bearer '
auth = prefix + tok_val
def call(method, path, data=None):
    url = 'https://api.cloudflare.com/client/v4' + path
    req = urllib.request.Request(url, method=method)
    req.add_header('Authorization', auth)
    req.add_header('Content-Type', 'application/json')
    body = data.encode() if data else None
    try:
        resp = urllib.request.urlopen(req, data=body, timeout=30)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {'success': False, 'errors': [{'message': str(e)}], 'http_status': e.code}
if len(sys.argv) < 3:
    print(json.dumps({'success': False, 'errors': [{'message': 'usage'}]}))
    sys.exit(1)
result = call(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
print(json.dumps(result))
PYHELPER

cf() { python3 /tmp/_cf.py "$1" "$2" "${3:-}"; }
rnd() { python3 -c "import random,string;print(''.join(random.choices(string.ascii_lowercase+string.digits,k=8)))"; }

echo ""
echo "  sing-box all-in-one proxy"
echo "  Public IP: $PUBLIC_IP"
echo ""

echo ">>> Verify token..."
cf GET /accounts > /tmp/_a.json
test "$(jq -r '.success' /tmp/_a.json)" = "true" || { echo "FAIL: bad token"; exit 1; }
ai=$(jq -r '.result[0].id' /tmp/_a.json)
test -z "$ai" -o "$ai" = "null" && { echo "No account."; exit 1; }

# Check for existing deployment
if test -f "$D/.state" -a "$FRESH" -ne 1; then
  ti=$(grep '^tunnel_id=' "$D/.state" | cut -d= -f2)
  ai2=$(grep '^account_id=' "$D/.state" | cut -d= -f2)
  zi=$(grep '^zone_id=' "$D/.state" | cut -d= -f2)
  z=$(grep '^zone_name=' "$D/.state" | cut -d= -f2)
  tn=$(grep '^tunnel_name=' "$D/.state" | cut -d= -f2)
  xh=$(echo "$(grep '^hosts=' "$D/.state" | cut -d= -f2)" | cut -d, -f1)
  sh=$(echo "$(grep '^hosts=' "$D/.state" | cut -d= -f2)" | cut -d, -f2)
  if test -f "/etc/cloudflared/$tn.token"; then tk=$(cat "/etc/cloudflared/$tn.token"); else tk=""; fi
  cf GET "/accounts/$ai2/tunnels/$ti" > /tmp/_t.json
  if test "$(jq -r '.success' /tmp/_t.json)" = "true" -a -n "$tk"; then
    echo ">>> Reusing existing deployment..."
    echo "  $z -> $xh / $sh"
    ai="$ai2"
  else
    echo ">>> Stale, recreating..."
    systemctl stop singbox-proxy cloudflared-proxy 2>/dev/null || true
    rm -f "$D/.state"; tk=""
  fi
fi

# Fresh deploy
if test ! -f "$D/.state"; then
  echo ">>> Zone..."
  cf GET "/zones?per_page=1&status=active" > /tmp/_z.json
  test "$(jq -r '.success' /tmp/_z.json)" = "true" || { echo "No zone."; exit 1; }
  z=$(jq -r '.result[0].name' /tmp/_z.json)
  test -z "$z" -o "$z" = "null" && { echo "No zone."; exit 1; }
  zi=$(jq -r '.result[0].id' /tmp/_z.json)
  pf=$(rnd)
  test -z "$xh" && xh="${pf}.${z}"
  test -z "$sh" && sh="${pf}-ws.${z}"
  test -z "$tn" && tn="vps-${pf}"
  echo "  $z -> $xh / $sh"

  echo ">>> Tunnel..."
  ts=$(python3 -c "import secrets,base64;print(base64.b64encode(secrets.token_bytes(32)).decode())")
  cf POST "/accounts/$ai/tunnels" "{\"name\":\"$tn\",\"tunnel_secret\":\"$ts\",\"config_src\":\"cloudflare\"}" > /tmp/_t.json
  ti=$(jq -r '.result.id' /tmp/_t.json)
  tk=$(jq -r '.result.token // empty' /tmp/_t.json)
  test -z "$ti" -o "$ti" = "null" && { echo "FAIL:"; cat /tmp/_t.json; exit 1; }
  test -z "$tk" && { echo "FAIL: no token"; exit 1; }

  echo ">>> DNS..."
  cn="$ti.cfargotunnel.com"
  for h in "$xh" "$sh"; do
    cf POST "/zones/$zi/dns_records" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /tmp/_dns.json
    test "$(jq -r '.success' /tmp/_dns.json)" = "true" && echo "  $h" || {
      ri=$(cf GET "/zones/$zi/dns_records?type=CNAME&name=$h" | jq -r '.result[0].id // empty')
      test -n "$ri" && { cf PATCH "/zones/$zi/dns_records/$ri" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null; echo "  $h (updated)"; }
    }
  done

  echo ">>> Ingress..."
  ig=$(python3 -c "import json;print(json.dumps({'config':{'ingress':[{'hostname':'$xh','service':'http://127.0.0.1:$xp','originRequest':{'noTLSVerify':True}},{'hostname':'$sh','service':'http://127.0.0.1:$sp','originRequest':{'noTLSVerify':True}},{'service':'http_status:404'}]}}))")
  cf PUT "/accounts/$ai/tunnels/$ti/configurations" "$ig" > /dev/null && echo "  OK"

  cat > "$D/.state" <<STATE
tunnel_id=$ti
tunnel_name=$tn
account_id=$ai
zone_id=$zi
zone_name=$z
hosts=$xh,$sh
public_ip=$PUBLIC_IP
reality_sni=$REALITY_SNI
created=$(date -Iseconds)
STATE
fi

echo ">>> Binaries..."
mkdir -p "$D" && cd "$D"
# Remove old xray if exists
rm -f ./xray ./xray.zip ./config.json 2>/dev/null

if test ! -x ./sing-box; then
  echo -n "  sing-box..."; ar=$(uname -m)
  case "$ar" in x86_64) sa=amd64;; aarch64) sa=arm64;; *) echo "Bad arch"; exit 1;; esac
  sb_url=$(python3 -c "
import json,urllib.request
r=json.loads(urllib.request.urlopen('https://api.github.com/repos/SagerNet/sing-box/releases/latest').read())
for a in r['assets']:
    n=a['name']
    if 'linux-' + '$sa' in n and n.endswith('.tar.gz') and 'musl' not in n:
        print(a['browser_download_url']); break
")
  test -z "$sb_url" -o "$sb_url" = "null" && { echo " FAIL"; exit 1; }
  curl -fsSLo /tmp/sb.tar.gz "$sb_url"
  tar -xzf /tmp/sb.tar.gz; mv sing-box-*/sing-box ./sing-box; chmod +x ./sing-box
  rm -rf /tmp/sb.tar.gz sing-box-*/; echo " OK"
fi
test -x /usr/local/bin/cloudflared || { echo -n "  cloudflared..."; curl -fsSLo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; chmod +x /usr/local/bin/cloudflared; echo " OK"; }

echo ">>> Keys..."
# Regenerate if missing or incomplete (need all 8 keys for v3)
_need_gen=0
test -f sb_keys.env || _need_gen=1
if test $_need_gen -eq 0; then
  . sb_keys.env
  for v in XRAY_UUID WS_UUID REALITY_UUID HY2_PASS TUIC_PASS TUIC_UUID REALITY_PUBKEY REALITY_PRIVKEY; do
    test -n "${!v:-}" || { _need_gen=1; break; }
  done
fi
if test $_need_gen -eq 1; then
  echo -n "  generating..."
  xu=$(./sing-box generate uuid)
  su=$(./sing-box generate uuid)
  ru=$(./sing-box generate uuid)
  hy_pass=$(python3 -c "import secrets;print(secrets.token_hex(32))")
  tu_pass=$(python3 -c "import secrets;print(secrets.token_hex(32))")
  tu_uuid=$(./sing-box generate uuid)
  rkp=$(./sing-box generate reality-keypair 2>/dev/null || echo "")
  if test -n "$rkp"; then
    rpk=$(echo "$rkp" | grep "PublicKey" | awk '{print $2}')
    rsk=$(echo "$rkp" | grep "PrivateKey" | awk '{print $2}')
  else
    rpk="REALITY_PUBKEY_PLACEHOLDER"
    rsk="REALITY_PRIVKEY_PLACEHOLDER"
  fi
  cat > sb_keys.env <<KEYS
XRAY_UUID=$xu
WS_UUID=$su
REALITY_UUID=$ru
HY2_PASS=$hy_pass
TUIC_PASS=$tu_pass
TUIC_UUID=$tu_uuid
REALITY_PUBKEY=$rpk
REALITY_PRIVKEY=$rsk
KEYS
  . sb_keys.env
  echo " done"
fi

echo ">>> sing-box config..."
# Write sing-box config with all 5 protocols
# Tunnel protocols bind 127.0.0.1, direct protocols bind 0.0.0.0
cat > sb-config.json <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "listen_port": $xp,
      "users": [{"uuid": "$XRAY_UUID"}],
      "transport": {"type": "httpupgrade", "path": "/xray"}
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": $sp,
      "users": [{"uuid": "$WS_UUID"}],
      "transport": {"type": "ws", "path": "/sing940"}
    },
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "0.0.0.0",
      "listen_port": $hp,
      "users": [{"password": "$HY2_PASS"}],
      "masquerade": "https://$REALITY_SNI",
      "tls": {
        "enabled": true,
        "certificate_path": "/opt/proxy/fullchain.pem",
        "key_path": "/opt/proxy/privkey.pem"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic",
      "listen": "0.0.0.0",
      "listen_port": $tp,
      "users": [{"uuid": "$TUIC_UUID", "password": "$TUIC_PASS"}],
      "tls": {
        "enabled": true,
        "certificate_path": "/opt/proxy/fullchain.pem",
        "key_path": "/opt/proxy/privkey.pem"
      }
    },
    {
      "type": "vless",
      "tag": "reality",
      "listen": "0.0.0.0",
      "listen_port": $rp,
      "users": [{"uuid": "$REALITY_UUID"}],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "private_key": "$REALITY_PRIVKEY",
          "short_id": ["$(openssl rand -hex 8 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(8))')"]
        }
      },
      "transport": {"type": "httpupgrade"}
    }
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

# Generate self-signed cert for HY2/TUIC (they need TLS cert)
if test ! -f "$D/fullchain.pem"; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "$D/privkey.pem" -out "$D/fullchain.pem" \
    -subj "/CN=$REALITY_SNI" 2>/dev/null
fi

echo ">>> Cloudflared..."
mkdir -p /etc/cloudflared
printf '%s' "$tk" > "/etc/cloudflared/$tn.token"; chmod 600 "/etc/cloudflared/$tn.token"
cat > /etc/cloudflared/config.yml <<YML
tunnel: $ti
no-autoupdate: true
ingress:
  - hostname: $xh
    service: http://127.0.0.1:$xp
    originRequest:
      noTLSVerify: true
  - hostname: $sh
    service: http://127.0.0.1:$sp
    originRequest:
      noTLSVerify: true
  - service: http_status:404
YML

echo ">>> Firewall..."
# Open direct protocol ports
for port in $hp $tp $rp; do
  iptables -I INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
  iptables -I INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
done

echo ">>> systemd..."
# Remove old xray unit
rm -f /etc/systemd/system/xray-proxy.service

cat > /etc/systemd/system/singbox-proxy.service <<'UNIT'
[Unit]
Description=Sing-box Proxy (all protocols)
After=network-online.target
[Service]
Type=simple
WorkingDirectory=/opt/proxy
ExecStart=/opt/proxy/sing-box run -c /opt/proxy/sb-config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/cloudflared-proxy.service <<UNIT
[Unit]
Description=CF Tunnel
After=network-online.target singbox-proxy.service
[Service]
Type=notify
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml --no-autoupdate run --token ${tk}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

# Stop old xray if running
systemctl stop xray-proxy 2>/dev/null || true
systemctl disable xray-proxy 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now singbox-proxy cloudflared-proxy
sleep 3

echo ">>> Status:"
for s in singbox-proxy cloudflared-proxy; do
  printf "  %-24s %s\n" "$s" "$(systemctl is-active $s 2>/dev/null || echo dead)"
done

echo ""
echo "=============================================="
echo " SERVER: $PUBLIC_IP"
echo "=============================================="
echo ""

# Tunnel protocols
echo "--- Tunnel protocols (CF Tunnel, hidden IP) ---"
echo ""

xh_uri="vless://${XRAY_UUID}@${xh}:443?encryption=none&security=tls&sni=${xh}&type=httpupgrade&host=${xh}&path=%2Fxray&fp=chrome#${tn}-XHTTP"
sh_uri="vless://${WS_UUID}@${sh}:443?encryption=none&security=tls&sni=${sh}&type=ws&host=${sh}&path=%2Fsing940#${tn}-WS"

echo "VLESS+XHTTP:"
echo "  $xh_uri"
echo ""
echo "VLESS+WS:"
echo "  $sh_uri"
echo ""

# Direct protocols
echo "--- Direct protocols (VPS IP: $PUBLIC_IP) ---"
echo ""

hy_uri="hysteria2://${HY2_PASS}@${PUBLIC_IP}:${hp}?insecure=1&sni=${REALITY_SNI}#${tn}-HY2"
tu_uri="tuic://${TUIC_UUID}:${TUIC_PASS}@${PUBLIC_IP}:${tp}?congestion_control=bbr&alpn=h3&sni=${REALITY_SNI}&allow_insecure=1#${tn}-TUIC"
re_uri="vless://${REALITY_UUID}@${PUBLIC_IP}:${rp}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&type=httpupgrade&pbk=${REALITY_PUBKEY}#${tn}-REALITY"

echo "Hysteria2:"
echo "  $hy_uri"
echo ""
echo "TUIC:"
echo "  $tu_uri"
echo ""
echo "Reality (VLESS):"
echo "  $re_uri"
echo ""

# ── Generate subscription files ──
echo ">>> Subscription..."
mkdir -p "$D/sub"

# v2ray sub (base64 encoded list of all URIs)
printf '%s\n%s\n%s\n%s\n%s\n' "$xh_uri" "$sh_uri" "$hy_uri" "$tu_uri" "$re_uri" | base64 -w0 > "$D/sub/v2ray.txt"

# Clash Meta YAML
cat > "$D/sub/clash.yaml" <<YAML
proxies:
  - name: "${tn}-XHTTP"
    type: vless
    server: ${xh}
    port: 443
    uuid: ${XRAY_UUID}
    tls: true
    client-fingerprint: chrome
    network: httpupgrade
    servername: ${xh}
    http-opts:
      path: "/xray"
      host: ["${xh}"]
  - name: "${tn}-WS"
    type: vless
    server: ${sh}
    port: 443
    uuid: ${WS_UUID}
    tls: true
    network: ws
    servername: ${sh}
    ws-opts:
      path: "/sing940"
      headers:
        Host: ${sh}
  - name: "${tn}-HY2"
    type: hysteria2
    server: ${PUBLIC_IP}
    port: ${hp}
    password: ${HY2_PASS}
    sni: ${REALITY_SNI}
    skip-cert-verify: true
  - name: "${tn}-TUIC"
    type: tuic
    server: ${PUBLIC_IP}
    port: ${tp}
    uuid: ${TUIC_UUID}
    password: ${TUIC_PASS}
    sni: ${REALITY_SNI}
    alpn: ["h3"]
    skip-cert-verify: true
  - name: "${tn}-Reality"
    type: vless
    server: ${PUBLIC_IP}
    port: ${rp}
    uuid: ${REALITY_UUID}
    tls: true
    reality-opts:
      public-key: ${REALITY_PUBKEY}
      short-id: ""
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    network: httpupgrade

proxy-groups:
  - name: "Auto"
    type: url-test
    proxies: ["${tn}-XHTTP", "${tn}-WS", "${tn}-HY2", "${tn}-TUIC", "${tn}-Reality"]
    url: "http://www.gstatic.com/generate_204"
    interval: 300
  - name: "Tunnel"
    type: select
    proxies: ["${tn}-XHTTP", "${tn}-WS"]
  - name: "Direct"
    type: select
    proxies: ["${tn}-HY2", "${tn}-TUIC", "${tn}-Reality"]

rules:
  - MATCH,Auto
YAML

# Symlinks for clean URLs
ln -sf v2ray.txt "$D/sub/sub" 2>/dev/null
ln -sf clash.yaml "$D/sub/clash" 2>/dev/null

# Start sub server (kill old first)
pkill -f 'sub/server.py' 2>/dev/null || true
sleep 1
nohup python3 "$D/sub/server.py" > /dev/null 2>&1 &
sleep 1

# Try CF VIP
echo ">>> CF VIP..."
vip_result=$(timeout 8 python3 -c "
import urllib.request, re
for url in ['https://raw.githubusercontent.com/ip-scanner/cloudflare/main/ip.txt', 'https://cf.090227.xyz']:
    try:
        data = urllib.request.urlopen(url, timeout=4).read().decode()
        ips = re.findall(r'\d+\.\d+\.\d+\.\d+', data)
        if ips: print(ips[0]); break
    except: pass
" 2>/dev/null || echo "")
vip_ip="$vip_result"
test -n "$vip_ip" && {
  vip_xh="vless://${XRAY_UUID}@${vip_ip}:443?encryption=none&security=tls&sni=${xh}&type=httpupgrade&host=${xh}&path=%2Fxray&fp=chrome#${tn}-XHTTP-VIP"
  vip_sh="vless://${WS_UUID}@${vip_ip}:443?encryption=none&security=tls&sni=${sh}&type=ws&host=${sh}&path=%2Fsing940#${tn}-WS-VIP"
}

# Write clients.txt
cat > clients.txt <<CEOF
=== Tunnel (CF Tunnel, hidden IP) ===
XHTTP: $xh_uri
WS:    $sh_uri

=== Direct (VPS: $PUBLIC_IP) ===
HY2:     $hy_uri
TUIC:    $tu_uri
Reality: $re_uri

=== Subscription ===
v2ray:  http://${PUBLIC_IP}:9091/sub
clash:  http://${PUBLIC_IP}:9091/clash
CEOF

echo ""
echo "=============================================="
echo " SERVER: $PUBLIC_IP"
echo "=============================================="
echo ""
echo "--- Tunnel (CF Tunnel) ---"
echo " $xh_uri"
echo ""
echo " $sh_uri"
test -n "$vip_ip" && {
  echo "--- VIP ---"
  echo " $vip_xh"
  echo ""
  echo " $vip_sh"
}
echo ""
echo "--- Direct ---"
echo " $hy_uri"
echo ""
echo " $tu_uri"
echo ""
echo " $re_uri"
echo ""
echo "--- Subscription ---"
echo " v2ray:  http://${PUBLIC_IP}:9091/sub"
echo " clash:  http://${PUBLIC_IP}:9091/clash"
echo ""
echo "=============================================="
echo " uninstall: sudo bash $D/scripts/uninstall.sh"
echo "=============================================="
