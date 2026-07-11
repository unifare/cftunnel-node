#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy
K=""; xh=""; sh=""; xp=20001; sp=20002; tn=""; FRESH=0

while test $# -gt 0; do
  case "$1" in
    --tok)         shift; K="$1" ;;
    --xray-host)   shift; xh="$1" ;;
    --sb-host)     shift; sh="$1" ;;
    --tunnel-name) shift; tn="$1" ;;
    --fresh)       FRESH=1; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

# No token: show status
test -z "${K}" && {
  if test -f "$D/.state"; then
    . "$D/.state"
    echo "=== Current ==="
    echo "  Zone:   $zone_name"
    echo "  WS:     $(echo $hosts | cut -d, -f1):443"
    echo "  WS-2:   $(echo $hosts | cut -d, -f2):443"
    echo ""
    test -f "$D/clients.txt" && cat "$D/clients.txt"
    exit 0
  fi
  echo "Usage: sudo bash install.sh --tok <CF_API_TOKEN>"
  exit 1
}
test "$EUID" -ne 0 && { echo "Run as root"; exit 1; }
apt-get update -qq && apt-get install -y -qq jq curl unzip qrencode 2>/dev/null

printf "%s" "$K" > /tmp/_cftok_val; chmod 600 /tmp/_cftok_val; trap 'rm -f /tmp/_cftok_val /tmp/_cf.py' EXIT

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

echo ">>> Verify..."
cf GET /accounts > /tmp/_a.json
test "$(jq -r '.success' /tmp/_a.json)" = "true" || { echo "FAIL: bad token"; exit 1; }
ai=$(jq -r '.result[0].id' /tmp/_a.json)
test -z "$ai" -o "$ai" = "null" && { echo "No account."; exit 1; }

# Reuse existing?
if test -f "$D/.state" -a "$FRESH" -ne 1; then
  ti=$(grep '^tunnel_id=' "$D/.state" | cut -d= -f2)
  ai2=$(grep '^account_id=' "$D/.state" | cut -d= -f2); ai="$ai2"
  zi=$(grep '^zone_id=' "$D/.state" | cut -d= -f2)
  z=$(grep '^zone_name=' "$D/.state" | cut -d= -f2)
  tn=$(grep '^tunnel_name=' "$D/.state" | cut -d= -f2)
  xh=$(echo "$(grep '^hosts=' "$D/.state" | cut -d= -f2)" | cut -d, -f1)
  sh=$(echo "$(grep '^hosts=' "$D/.state" | cut -d= -f2)" | cut -d, -f2)
  test -f "/etc/cloudflared/$tn.token" && tk=$(cat "/etc/cloudflared/$tn.token") || tk=""
  cf GET "/accounts/$ai2/tunnels/$ti" > /tmp/_t.json
  if test "$(jq -r '.success' /tmp/_t.json)" = "true" -a -n "$tk"; then
    echo ">>> Reusing: $z -> $xh / $sh"
  else
    systemctl stop singbox-proxy cloudflared-proxy 2>/dev/null || true
    rm -f "$D/.state"; tk=""
  fi
fi

# Fresh deploy
if test ! -f "$D/.state"; then
  cf GET "/zones?per_page=1&status=active" > /tmp/_z.json
  test "$(jq -r '.success' /tmp/_z.json)" = "true" || { echo "No zone."; exit 1; }
  z=$(jq -r '.result[0].name' /tmp/_z.json)
  test -z "$z" -o "$z" = "null" && { echo "No zone."; exit 1; }
  zi=$(jq -r '.result[0].id' /tmp/_z.json)
  pf=$(rnd)
  test -z "$xh" && xh="${pf}.${z}"
  test -z "$sh" && sh="${pf}-ws.${z}"
  test -z "$tn" && tn="vps-${pf}"
  echo ">>> Zone: $z -> $xh / $sh"

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

  cf PUT "/accounts/$ai/tunnels/$ti/configurations" "$(python3 -c "import json;print(json.dumps({'config':{'ingress':[{'hostname':'$xh','service':'http://127.0.0.1:$xp','originRequest':{'noTLSVerify':True}},{'hostname':'$sh','service':'http://127.0.0.1:$sp','originRequest':{'noTLSVerify':True}},{'service':'http_status:404'}]}}))")" > /dev/null

  cat > "$D/.state" <<STATE
tunnel_id=$ti
tunnel_name=$tn
account_id=$ai
zone_id=$zi
zone_name=$z
hosts=$xh,$sh
created=$(date -Iseconds)
STATE
fi

echo ">>> Binaries..."
mkdir -p "$D" && cd "$D"
rm -f ./xray ./xray.zip ./config.json ./fullchain.pem ./privkey.pem 2>/dev/null
rm -rf ./sub 2>/dev/null

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
_need_gen=0
test -f sb_keys.env || _need_gen=1
if test $_need_gen -eq 0; then
  . sb_keys.env
  test -n "${UUID1:-}" -a -n "${UUID2:-}" || _need_gen=1
fi
if test $_need_gen -eq 1; then
  u1=$(./sing-box generate uuid); u2=$(./sing-box generate uuid)
  cat > sb_keys.env <<KEYS
UUID1=$u1
UUID2=$u2
KEYS
  . sb_keys.env
fi

echo ">>> Config..."
# Simple sing-box: 2 VLESS+WS inbounds on 127.0.0.1
cat > sb-config.json <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "vless", "listen": "127.0.0.1", "listen_port": $xp,
     "users": [{"uuid": "$UUID1"}], "transport": {"type": "ws", "path": "/xray"}},
    {"type": "vless", "listen": "127.0.0.1", "listen_port": $sp,
     "users": [{"uuid": "$UUID2"}], "transport": {"type": "ws", "path": "/sing940"}}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

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

echo ">>> systemd..."
rm -f /etc/systemd/system/xray-proxy.service

cat > /etc/systemd/system/singbox-proxy.service <<'UNIT'
[Unit]
Description=Sing-box Proxy
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

systemctl stop xray-proxy 2>/dev/null || true
systemctl disable xray-proxy 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now singbox-proxy cloudflared-proxy
sleep 3

u1="vless://${UUID1}@${xh}:443?encryption=none&security=tls&sni=${xh}&type=ws&host=${xh}&path=%2Fxray&fp=chrome#${tn}-1"
u2="vless://${UUID2}@${sh}:443?encryption=none&security=tls&sni=${sh}&type=ws&host=${sh}&path=%2Fsing940#${tn}-2"

cat > clients.txt <<EOF
$u1
$u2
EOF

echo ""
echo "=== $(systemctl is-active singbox-proxy) / $(systemctl is-active cloudflared-proxy) ==="
echo ""
echo "$u1"
echo "$u2"
echo ""
qrencode -t ANSIUTF8 "$u1" 2>/dev/null || echo "[QR unavailable]"
echo ""
qrencode -t ANSIUTF8 "$u2" 2>/dev/null || echo "[QR unavailable]"
echo ""
echo "  uninstall: sudo bash $D/scripts/uninstall.sh"
