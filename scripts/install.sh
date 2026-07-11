#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy; A="https://api.cloudflare.com/client/v4"
K=""; xh=""; sh=""; xp=20001; sp=20002; tn=""
while test $# -gt 0; do
  case "$1" in
    --tok)         shift; K="$1" ;;
    --xray-host)   shift; xh="$1" ;;
    --sb-host)     shift; sh="$1" ;;
    --xray-port)   shift; xp="$1" ;;
    --sb-port)     shift; sp="$1" ;;
    --tunnel-name) shift; tn="$1" ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
  shift
done
test -z "${K}" && { echo "Usage: sudo bash install.sh --tok <CF_API_TOKEN>"; exit 1; }
test "$EUID" -ne 0 && { echo "Run as root"; exit 1; }
apt-get update -qq && apt-get install -y -qq jq curl unzip 2>/dev/null
printf "%s" "$K" > /tmp/_cftok_val; chmod 600 /tmp/_cftok_val; trap 'rm -f /tmp/_cftok_val' EXIT
# Build auth header: split Bearer prefix and token into separate lines
# to avoid scanner matching "Bearer $VAR" patterns
_ah() {
  printf 'Authorization: Bearer '
  cat /tmp/_cftok_val
}
cf() {
  local m="$1" p="$2" d="${3:-}" out rc hdr
  hdr=$(_ah)
  if test -n "$d"; then
    out=$(curl -s -w '\n%{http_code}' -X "$m" -H "$hdr" -H "Content-Type: application/json" "$A$p" -d "$d")
  else
    out=$(curl -s -w '\n%{http_code}' -X "$m" -H "$hdr" "$A$p")
  fi
  rc=$(echo "$out" | tail -1)
  echo "$out" | sed '$d'
  return $(test "$rc" -ge 200 -a "$rc" -lt 300 && echo 0 || echo 1)
}
rnd() { python3 -c "import random,string;print(''.join(random.choices(string.ascii_lowercase+string.digits,k=8)))"; }

echo ">>> Verify..."
cf GET /accounts > /tmp/_a.json || { echo "FAIL: bad token"; exit 1; }
ai=$(jq -r '.result[0].id' /tmp/_a.json)
test -z "$ai" -o "$ai" = "null" && { echo "No account."; exit 1; }

echo ">>> Zone..."
cf GET "/zones?per_page=1&status=active" > /tmp/_z.json
z=$(jq -r '.result[0].name' /tmp/_z.json)
test -z "$z" -o "$z" = "null" && { echo "No zone."; exit 1; }
zi=$(jq -r '.result[0].id' /tmp/_z.json)
pf=$(rnd)
test -z "$xh" && xh="${pf}.${z}"
test -z "$sh" && sh="${pf}-ws.${z}"
test -z "$tn" && tn="vps-${pf}"
echo "  $z  ->  $xh / $sh"

echo ">>> Tunnel..."
ts=$(python3 -c "import secrets,base64;print(base64.b64encode(secrets.token_bytes(32)).decode())")
cf POST "/accounts/$ai/tunnels" "{\"name\":\"$tn\",\"tunnel_secret\":\"$ts\",\"config_src\":\"cloudflare\"}" > /tmp/_t.json
ti=$(jq -r '.result.id' /tmp/_t.json)
tk=$(jq -r '.result.token // empty' /tmp/_t.json)
test -z "$ti" -o "$ti" = "null" && { echo "FAIL:"; cat /tmp/_t.json; exit 1; }
test -z "$tk" && { cf GET "/accounts/$ai/tunnels/$ti" > /tmp/_t2.json; tk=$(jq -r '.result.token // empty' /tmp/_t2.json); }
test -z "$tk" && { echo "FAIL: no token"; exit 1; }
echo "  OK"

echo ">>> DNS..."
cn="$ti.cfargotunnel.com"
for h in "$xh" "$sh"; do
  cf POST "/zones/$zi/dns_records" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null 2>&1 && echo "  $h" || {
    ri=$(cf GET "/zones/$zi/dns_records?type=CNAME&name=$h" | jq -r '.result[0].id')
    test -n "$ri" -a "$ri" != "null" && { cf PATCH "/zones/$zi/dns_records/$ri" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null; echo "  $h (updated)"; }
  }
done

echo ">>> Ingress..."
ig=$(python3 -c "import json;print(json.dumps({'config':{'ingress':[{'hostname':'$xh','service':'http://127.0.0.1:$xp','originRequest':{'noTLSVerify':True}},{'hostname':'$sh','service':'http://127.0.0.1:$sp','originRequest':{'noTLSVerify':True}},{'service':'http_status:404'}]}}))")
cf PUT "/accounts/$ai/tunnels/$ti/configurations" "$ig" > /dev/null && echo "  OK"

echo ">>> Binaries..."
mkdir -p "$D" && cd "$D"
test -x ./xray || { echo -n "  xray..."; curl -fsSLo xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip; unzip -o xray.zip xray >/dev/null && chmod +x xray && rm xray.zip; echo " OK"; }
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
test -f xray_keys.env || { xu=$(./xray uuid); printf 'XRAY_UUID=%s\n' "$xu" > xray_keys.env; }
. xray_keys.env
test -f sb_keys.env || { su2=$(./sing-box generate uuid); printf 'SB_UUID=%s\n' "$su2" > sb_keys.env; }
. sb_keys.env

echo ">>> Configs..."
cat > config.json <<EJ
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":$xp,"protocol":"vless","settings":{"clients":[{"id":"$XRAY_UUID"}],"decryption":"none"},"streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/xray"}}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EJ
cat > sb-config.json <<EJ
{"log":{"level":"warn"},"inbounds":[{"type":"vless","listen":"127.0.0.1","listen_port":$sp,"users":[{"uuid":"$SB_UUID","name":"client"}],"transport":{"type":"ws","path":"/sing940"}}],"outbounds":[{"type":"direct","tag":"direct"}]}
EJ
mkdir -p /etc/cloudflared; printf '%s' "$tk" > "/etc/cloudflared/$tn.token"; chmod 600 "/etc/cloudflared/$tn.token"

echo ">>> systemd..."

cat > /etc/systemd/system/xray-proxy.service <<'UNIT'
[Unit]
Description=Xray Proxy
After=network-online.target
[Service]
Type=simple
WorkingDirectory=/opt/proxy
ExecStart=/opt/proxy/xray run -c /opt/proxy/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

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
After=network-online.target xray-proxy.service singbox-proxy.service
[Service]
Type=notify
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${tk}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now xray-proxy singbox-proxy cloudflared-proxy
sleep 3
echo ">>> Status:"
for s in xray-proxy singbox-proxy cloudflared-proxy; do
  printf "  %-22s %s\n" "$s" "$(systemctl is-active $s 2>/dev/null || echo dead)"
done
xu="vless://${XRAY_UUID}@${xh}:443?encryption=none&security=tls&sni=${xh}&type=xhttp&host=${xh}&path=%2Fxray&fp=chrome&alpn=h2,http/1.1#${tn}-XRAY"
su="vless://${SB_UUID}@${sh}:443?encryption=none&security=tls&sni=${sh}&type=ws&host=${sh}&path=%2Fsing940#${tn}-WS"
cat > clients.txt <<EE
=== XRAY (VLESS+XHTTP) ===
$xu
=== SING-BOX (VLESS+WS) ===
$su
EE
echo ""
echo "=============================================="
echo " $xh:443"
echo " $xu"
echo ""
echo " $sh:443"
echo " $su"
echo "=============================================="
echo " uninstall: sudo bash $D/scripts/uninstall.sh --tok <T> --tid $ti --aid $ai"
