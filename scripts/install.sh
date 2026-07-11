#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy
K=""; pf=""; tn=""; FRESH=0

while test $# -gt 0; do
  case "$1" in
    --tok)         shift; K="$1" ;;
    --tunnel-name) shift; tn="$1" ;;
    --fresh)       FRESH=1; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done

test -z "${K}" && {
  if test -f "$D/.state"; then
    . "$D/.state"; echo "=== Current ==="; echo "  Host: $host1"; echo ""
    test -f "$D/clients.txt" && cat "$D/clients.txt"; exit 0
  fi
  echo "Usage: sudo bash install.sh --tok <CF_API_TOKEN>"; exit 1
}
test "$EUID" -ne 0 && { echo "Run as root"; exit 1; }
apt-get update -qq && apt-get install -y -qq jq curl unzip qrencode 2>/dev/null

printf "%s" "$K" > /tmp/_cftok_val; chmod 600 /tmp/_cftok_val; trap 'rm -f /tmp/_cftok_val /tmp/_cf.py' EXIT

cat > /tmp/_cf.py << 'PYHELPER'
import sys, json, urllib.request
t=open('/tmp/_cftok_val').read().strip();a='Bearer '+t
def c(m,p,d=None):
    r=urllib.request.Request('https://api.cloudflare.com/client/v4'+p,method=m)
    r.add_header('Authorization',a);r.add_header('Content-Type','application/json')
    b=d.encode() if d else None
    try:return json.loads(urllib.request.urlopen(r,data=b,timeout=30).read())
    except urllib.error.HTTPError as e:return{'success':False,'errors':[{'message':str(e)}]}
if len(sys.argv)<3:print(json.dumps({'success':False}));sys.exit(1)
print(json.dumps(c(sys.argv[1],sys.argv[2],sys.argv[3]if len(sys.argv)>3 else None)))
PYHELPER

cf() { python3 /tmp/_cf.py "$1" "$2" "${3:-}"; }
rnd() { python3 -c "import random,string;print(''.join(random.choices(string.ascii_lowercase+string.digits,k=8)))"; }

echo ">>> Verify..."
cf GET /accounts > /tmp/_a.json
test "$(jq -r '.success' /tmp/_a.json)" = "true" || { echo "FAIL: bad token"; exit 1; }
ai=$(jq -r '.result[0].id' /tmp/_a.json)
test -z "$ai" -o "$ai" = "null" && { echo "No account."; exit 1; }

# Reuse?
if test -f "$D/.state" -a "$FRESH" -ne 1; then
  ti=$(grep '^tunnel_id=' "$D/.state" | cut -d= -f2); ai=$(grep '^account_id=' "$D/.state" | cut -d= -f2)
  zi=$(grep '^zone_id=' "$D/.state" | cut -d= -f2); z=$(grep '^zone_name=' "$D/.state" | cut -d= -f2)
  tn=$(grep '^tunnel_name=' "$D/.state" | cut -d= -f2)
  h1=$(grep '^host1=' "$D/.state" | cut -d= -f2); h2=$(grep '^host2=' "$D/.state" | cut -d= -f2)
  h3=$(grep '^host3=' "$D/.state" | cut -d= -f2); h4=$(grep '^host4=' "$D/.state" | cut -d= -f2)
  test -f "/etc/cloudflared/$tn.token" && tk=$(cat "/etc/cloudflared/$tn.token") || tk=""
  cf GET "/accounts/$ai/tunnels/$ti" > /tmp/_t.json
  if test "$(jq -r '.success' /tmp/_t.json)" = "true" -a -n "$tk"; then
    echo ">>> Reusing: $z -> $h1 / $h2 / $h3 / $h4"
  else
    systemctl stop singbox-proxy cloudflared-proxy 2>/dev/null || true; rm -f "$D/.state"; tk=""
  fi
fi

# Fresh
if test ! -f "$D/.state"; then
  cf GET "/zones?per_page=1&status=active" > /tmp/_z.json
  test "$(jq -r '.success' /tmp/_z.json)" = "true" || { echo "No zone."; exit 1; }
  z=$(jq -r '.result[0].name' /tmp/_z.json); zi=$(jq -r '.result[0].id' /tmp/_z.json)
  test -z "$z" -o "$z" = "null" && { echo "No zone."; exit 1; }
  pf=$(rnd); test -z "$tn" && tn="vps-${pf}"
  h1="${pf}.${z}"; h2="${pf}-2.${z}"; h3="${pf}-vm.${z}"; h4="${pf}-tr.${z}"
  echo ">>> Zone: $z"
  for h in "$h1" "$h2" "$h3" "$h4"; do echo "  $h"; done

  echo ">>> Tunnel..."
  ts=$(python3 -c "import secrets,base64;print(base64.b64encode(secrets.token_bytes(32)).decode())")
  cf POST "/accounts/$ai/tunnels" "{\"name\":\"$tn\",\"tunnel_secret\":\"$ts\",\"config_src\":\"cloudflare\"}" > /tmp/_t.json
  ti=$(jq -r '.result.id' /tmp/_t.json); tk=$(jq -r '.result.token // empty' /tmp/_t.json)
  test -z "$ti" -o "$ti" = "null" && { echo "FAIL:"; cat /tmp/_t.json; exit 1; }
  test -z "$tk" && { echo "FAIL: no token"; exit 1; }

  echo ">>> DNS..."
  cn="$ti.cfargotunnel.com"
  for h in "$h1" "$h2" "$h3" "$h4"; do
    cf POST "/zones/$zi/dns_records" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /tmp/_dns.json
    test "$(jq -r '.success' /tmp/_dns.json)" = "true" && echo "  $h" || {
      ri=$(cf GET "/zones/$zi/dns_records?type=CNAME&name=$h" | jq -r '.result[0].id // empty')
      test -n "$ri" && { cf PATCH "/zones/$zi/dns_records/$ri" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null; echo "  $h (updated)"; }
    }
  done

  # Ingress: each subdomain -> its own port
  cf PUT "/accounts/$ai/tunnels/$ti/configurations" "$(python3 -c "
import json
print(json.dumps({'config':{'ingress':[
    {'hostname':'$h1','service':'http://127.0.0.1:20001','originRequest':{'noTLSVerify':True}},
    {'hostname':'$h2','service':'http://127.0.0.1:20002','originRequest':{'noTLSVerify':True}},
    {'hostname':'$h3','service':'http://127.0.0.1:20003','originRequest':{'noTLSVerify':True}},
    {'hostname':'$h4','service':'http://127.0.0.1:20004','originRequest':{'noTLSVerify':True}},
    {'service':'http_status:404'}
]}}))")" > /dev/null

  cat > "$D/.state" <<STATE
tunnel_id=$ti
tunnel_name=$tn
account_id=$ai
zone_id=$zi
zone_name=$z
host1=$h1
host2=$h2
host3=$h3
host4=$h4
created=$(date -Iseconds)
STATE
fi

echo ">>> Binaries..."
mkdir -p "$D" && cd "$D"
rm -f ./xray ./xray.zip ./config.json ./fullchain.pem ./privkey.pem 2>/dev/null; rm -rf ./sub 2>/dev/null
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
  curl -fsSLo /tmp/sb.tar.gz "$sb_url"; tar -xzf /tmp/sb.tar.gz; mv sing-box-*/sing-box ./sing-box; chmod +x ./sing-box
  rm -rf /tmp/sb.tar.gz sing-box-*/; echo " OK"
fi
test -x /usr/local/bin/cloudflared || { echo -n "  cloudflared..."; curl -fsSLo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; chmod +x /usr/local/bin/cloudflared; echo " OK"; }

echo ">>> Keys..."
_need_gen=0; test -f sb_keys.env || _need_gen=1
if test $_need_gen -eq 0; then . sb_keys.env; for v in U1 U2 U3 U4 TP; do test -n "${!v:-}" || { _need_gen=1; break; }; done; fi
if test $_need_gen -eq 1; then
  u1=$(./sing-box generate uuid); u2=$(./sing-box generate uuid); u3=$(./sing-box generate uuid)
  u4=$(./sing-box generate uuid); tp=$(python3 -c "import secrets;print(secrets.token_hex(16))")
  cat > sb_keys.env <<KEYS
U1=$u1
U2=$u2
U3=$u3
U4=$u4
TP=$tp
KEYS
  . sb_keys.env
fi

echo ">>> Config..."
cat > sb-config.json <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "vless",  "listen": "127.0.0.1", "listen_port": 20001, "users": [{"uuid": "$U1"}], "transport": {"type": "ws", "path": "/vl1"}},
    {"type": "vless",  "listen": "127.0.0.1", "listen_port": 20002, "users": [{"uuid": "$U2"}], "transport": {"type": "ws", "path": "/vl2"}},
    {"type": "vmess",  "listen": "127.0.0.1", "listen_port": 20003, "users": [{"uuid": "$U3"}], "transport": {"type": "ws", "path": "/vm"}},
    {"type": "trojan", "listen": "127.0.0.1", "listen_port": 20004, "users": [{"password": "$TP"}], "transport": {"type": "ws", "path": "/tr"}}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

mkdir -p /etc/cloudflared; printf '%s' "$tk" > "/etc/cloudflared/$tn.token"; chmod 600 "/etc/cloudflared/$tn.token"
cat > /etc/cloudflared/config.yml <<YML
tunnel: $ti
no-autoupdate: true
ingress:
  - hostname: $h1
    service: http://127.0.0.1:20001
    originRequest: {noTLSVerify: true}
  - hostname: $h2
    service: http://127.0.0.1:20002
    originRequest: {noTLSVerify: true}
  - hostname: $h3
    service: http://127.0.0.1:20003
    originRequest: {noTLSVerify: true}
  - hostname: $h4
    service: http://127.0.0.1:20004
    originRequest: {noTLSVerify: true}
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

systemctl stop xray-proxy 2>/dev/null || true; systemctl disable xray-proxy 2>/dev/null || true
systemctl daemon-reload; systemctl enable --now singbox-proxy cloudflared-proxy
sleep 3

# Build URIs
vl1="vless://${U1}@${h1}:443?encryption=none&security=tls&sni=${h1}&type=ws&host=${h1}&path=%2Fvl1&fp=chrome#${tn}-VL1"
vl2="vless://${U2}@${h2}:443?encryption=none&security=tls&sni=${h2}&type=ws&host=${h2}&path=%2Fvl2#${tn}-VL2"
vm="vmess://$(echo -n "{\"v\":\"2\",\"ps\":\"${tn}-VM\",\"add\":\"${h3}\",\"port\":\"443\",\"id\":\"${U3}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${h3}\",\"path\":\"/vm\",\"tls\":\"tls\",\"sni\":\"${h3}\"}" | base64 -w0)"
tr="trojan://${TP}@${h4}:443?security=tls&sni=${h4}&type=ws&host=${h4}&path=%2Ftr#${tn}-TR"

cat > clients.txt <<EOF
$vl1
$vl2
$vm
$tr
EOF

echo ""
echo "=== active / active ==="
echo ""
echo "$vl1"
echo "$vl2"
echo "$vm"
echo "$tr"
echo ""
for u in "$vl1" "$vl2" "$vm" "$tr"; do qrencode -t ANSIUTF8 "$u" 2>/dev/null; echo ""; done
echo "  uninstall: sudo bash $D/scripts/uninstall.sh"
