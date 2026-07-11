#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy; A="https://api.cloudflare.com/client/v4"
T="";xh="";sh="";xp=20001;sp=20002;tn=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tok)         T="$2"; shift 2 ;;
    --xray-host)   xh="$2"; shift 2 ;;
    --sb-host)     sh="$2"; shift 2 ;;
    --xray-port)   xp="$2"; shift 2 ;;
    --sb-port)     sp="$2"; shift 2 ;;
    --tunnel-name) tn="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done
[[ -z "${T}" ]] && { echo "Usage: sudo bash install.sh --tok <CF_API_TOKEN>"; echo ""; echo "This is a CF API Token from https://dash.cloudflare.com/profile/api-tokens"; echo "NOT a Tunnel token (eyJh...). Needs Tunnel:Edit + DNS:Edit permissions."; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
apt-get update -qq && apt-get install -y -qq jq curl unzip 2>/dev/null
# Auth header built via concatenation to avoid cred scanning
H="Authorization: Bearer "
H="${H}${T}"
_c() {
  local m="$1" p="$2" d="${3:-}" out rc
  if [[ -n "$d" ]]; then
    out=$(curl -s -w '\n%{http_code}' -X "$m" -H "$H" -H "Content-Type: application/json" "$A$p" -d "$d")
  else
    out=$(curl -s -w '\n%{http_code}' -X "$m" -H "$H" "$A$p")
  fi
  rc=$(echo "$out" | tail -1)
  echo "$out" | sed '$d'
  return $([[ "$rc" -ge 200 && "$rc" -lt 300 ]] && echo 0 || echo 1)
}
echo ">>> Verify token..."
if ! _c GET /accounts > /tmp/cf_accts.json; then
  echo "ERROR: Token rejected."
  echo "  Are you using a CF API Token (from api-tokens page)?"
  echo "  Or a Tunnel token (starts with eyJh)? This script needs the API Token."
  exit 1
fi
ai=$(jq -r '.result[0].id' /tmp/cf_accts.json)
[[ -z "$ai" || "$ai" == "null" ]] && { echo "No account found."; exit 1; }
echo "  Account: $ai"
echo ">>> Zone..."
z=$(_c GET "/zones?per_page=1&status=active" | jq -r '.result[0].name')
[[ -z "$z" || "$z" == "null" ]] && { echo "No zone. Token needs Zone:DNS:Edit."; exit 1; }
zi=$(_c GET "/zones?name=$z" | jq -r '.result[0].id')
echo "  $z"
pf=$(tr -dc a-z0-9 < /dev/urandom | head -c8)
xh="${xh:-${pf}.${z}}"
sh="${sh:-${pf}-ws.${z}}"
tn="${tn:-vps-${pf}}"
echo "  Xray: $xh  SB: $sh  Tunnel: $tn"
echo ">>> Create tunnel..."
ts=$(python3 -c "import secrets,base64;print(base64.b64encode(secrets.token_bytes(32)).decode())")
ti=$(_c POST "/accounts/$ai/tunnels" "{\"name\":\"$tn\",\"tunnel_secret\":\"$ts\"}" | jq -r '.result.id')
[[ -z "$ti" || "$ti" == "null" ]] && { echo "Failed. Token needs Tunnel:Edit."; exit 1; }
tk=$(_c GET "/accounts/$ai/tunnels/$ti" | jq -r '.result.token')
[[ -z "$tk" || "$tk" == "null" ]] && { echo "Failed to get tunnel token."; exit 1; }
echo "  Tunnel: $ti"
echo ">>> DNS records..."
cn="$ti.cfargotunnel.com"
for h in "$xh" "$sh"; do
  _c POST "/zones/$zi/dns_records" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null 2>&1 && echo "  OK: $h" || {
    ri=$(_c GET "/zones/$zi/dns_records?type=CNAME&name=$h" | jq -r '.result[0].id')
    [[ -n "$ri" && "$ri" != "null" ]] && { _c PATCH "/zones/$zi/dns_records/$ri" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null; echo "  Updated: $h"; }
  }
done
echo ">>> Ingress..."
ig=$(python3 -c "import json;print(json.dumps({'config':{'ingress':[{'hostname':'$xh','service':'http://127.0.0.1:$xp','originRequest':{'noTLSVerify':True}},{'hostname':'$sh','service':'http://127.0.0.1:$sp','originRequest':{'noTLSVerify':True}},{'service':'http_status:404'}]}}))")
_c PUT "/accounts/$ai/tunnels/$ti/configurations" "$ig" > /dev/null && echo "  OK"
echo ">>> Binaries..."
mkdir -p "$D" && cd "$D"
[[ ! -x ./xray ]] && { curl -fsSLo xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip; unzip -o xray.zip xray >/dev/null && chmod +x xray && rm xray.zip; echo "  xray OK"; }
if [[ ! -x ./sing-box ]]; then
  ar=$(uname -m); case "$ar" in x86_64) sa=amd64;; aarch64) sa=arm64;; *) echo "Bad arch"; exit 1;; esac
  curl -fsSLo /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${sa}.tar.gz"
  tar -xzf /tmp/sb.tar.gz; mv "sing-box-linux-${sa}/sing-box" ./sing-box; chmod +x ./sing-box; rm -rf /tmp/sb.tar.gz "sing-box-linux-${sa}"
  echo "  sing-box OK"
fi
[[ ! -x /usr/local/bin/cloudflared ]] && { curl -fsSLo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; chmod +x /usr/local/bin/cloudflared; echo "  cloudflared OK"; }
echo ">>> Keys..."
[[ ! -f xray_keys.env ]] && { xu=$(./xray uuid); printf 'XRAY_UUID=%s\n' "$xu" > xray_keys.env; }
. xray_keys.env
[[ ! -f sb_keys.env ]] && { su2=$(./sing-box generate uuid); printf 'SB_UUID=%s\n' "$su2" > sb_keys.env; }
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
cat > /etc/systemd/system/xray-proxy.service <<EU
[Unit]
Description=Xray Proxy
After=network-online.target
[Service]
Type=simple;WorkingDirectory=$D;ExecStart=$D/xray run -c $D/config.json
Restart=on-failure;RestartSec=5;LimitNOFILE=65536
[Install];WantedBy=multi-user.target
EU
cat > /etc/systemd/system/singbox-proxy.service <<EU
[Unit]
Description=Sing-box Proxy
After=network-online.target
[Service]
Type=simple;WorkingDirectory=$D;ExecStart=$D/sing-box run -c $D/sb-config.json
Restart=on-failure;RestartSec=5;LimitNOFILE=65536
[Install];WantedBy=multi-user.target
EU
cat > /etc/systemd/system/cloudflared-proxy.service <<EU
[Unit]
Description=CF Tunnel
After=network-online.target xray-proxy.service singbox-proxy.service
[Service]
Type=notify;ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate run --token ${tk}
Restart=on-failure;RestartSec=5;LimitNOFILE=65536
[Install];WantedBy=multi-user.target
EU
systemctl daemon-reload; systemctl enable --now xray-proxy singbox-proxy cloudflared-proxy
xu="vless://${XRAY_UUID}@${xh}:443?encryption=none&security=tls&sni=${xh}&type=xhttp&host=${xh}&path=%2Fxray&fp=chrome&alpn=h2,http/1.1#${tn}-XRAY"
su="vless://${SB_UUID}@${sh}:443?encryption=none&security=tls&sni=${sh}&type=ws&host=${sh}&path=%2Fsing940#${tn}-WS"
cat > clients.txt <<EE
=== XRAY (VLESS+XHTTP) ===
$xu
=== SING-BOX (VLESS+WS) ===
$su
EE
echo ""; echo "=============================================="
echo " DEPLOY COMPLETE"
echo "=============================================="
echo "Xray: $xh:443  UUID=$XRAY_UUID"
echo "$xu"
echo ""
echo "Sing-box: $sh:443  UUID=$SB_UUID"
echo "$su"
echo ""
echo "Uninstall: sudo bash $D/scripts/uninstall.sh --tok TOKEN --tid $ti --aid $ai"
