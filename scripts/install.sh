#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy; A="https://api.cloudflare.com/client/v4"
t="";xh="";sh="";xp=20001;sp=20002;tn=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tok)         t="$2"; shift 2 ;;
    --xray-host)   xh="$2"; shift 2 ;;
    --sb-host)     sh="$2"; shift 2 ;;
    --xray-port)   xp="$2"; shift 2 ;;
    --sb-port)     sp="$2"; shift 2 ;;
    --tunnel-name) tn="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done
[[ -z "${t}" ]] && { echo "Usage: sudo bash install.sh --tok <CF_API_TOKEN>"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
apt-get update -qq && apt-get install -y -qq jq curl unzip 2>/dev/null
_c() {
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then curl -sf -X "$m" -H "Authorization: Bearer *** -H "Content-Type: application/json" "$A$p" -d "$d"
  else curl -sf -X "$m" -H "Authorization: Bearer *** "$A$p"; fi
}
echo ">>> Verify token..."
_c GET /user/tokens/verify | python3 -c "import sys,json;sys.exit(0 if json.load(sys.stdin).get('success') else 1)" || { echo "BAD TOKEN"; exit 1; }
echo ">>> Account..."
ai=$(_c GET /accounts | jq -r '.result[0].id')
[[ -z "$ai" || "$ai" == "null" ]] && { echo "No account"; exit 1; }
echo ">>> Zone (auto-detect)..."
z=$(_c GET "/zones?per_page=1&status=active" | jq -r '.result[0].name')
[[ -z "$z" || "$z" == "null" ]] && { echo "No active zone found"; exit 1; }
zi=$(_c GET "/zones?name=$z" | jq -r '.result[0].id')
echo "  Using: $z"
# Random prefix for hostnames
pf=$(tr -dc a-z0-9 < /dev/urandom | head -c8)
xh="${xh:-${pf}.${z}}"
sh="${sh:-${pf}-ws.${z}}"
tn="${tn:-vps-${pf}}"
echo "=== Zone:$z Xray:$xh:$xp SB:$sh:$sp Tunnel:$tn ==="
echo ">>> Tunnel..."
ts=$(python3 -c "import secrets,base64;print(base64.b64encode(secrets.token_bytes(32)).decode())")
ti=$(_c POST "/accounts/$ai/tunnels" "{\"name\":\"$tn\",\"tunnel_secret\":\"$ts\"}" | jq -r '.result.id')
[[ -z "$ti" || "$ti" == "null" ]] && { echo "Tunnel fail"; exit 1; }
tk=$(_c GET "/accounts/$ai/tunnels/$ti" | jq -r '.result.token')
[[ -z "$tk" || "$tk" == "null" ]] && { echo "Token fail"; exit 1; }
echo ">>> DNS..."
cn="$ti.cfargotunnel.com"
for h in "$xh" "$sh"; do
  _c POST "/zones/$zi/dns_records" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null 2>&1 && echo "  OK: $h" || {
    ri=$(_c GET "/zones/$zi/dns_records?type=CNAME&name=$h" | jq -r '.result[0].id')
    [[ -n "$ri" && "$ri" != "null" ]] && { _c PATCH "/zones/$zi/dns_records/$ri" "{\"type\":\"CNAME\",\"name\":\"$h\",\"content\":\"$cn\",\"proxied\":true}" > /dev/null; echo "  Updated: $h"; }
  }
done
echo ">>> Ingress..."
ig=$(python3 -c "import json;print(json.dumps({'config':{'ingress':[{'hostname':'$xh','service':'http://127.0.0.1:$xp','originRequest':{'noTLSVerify':True}},{'hostname':'$sh','service':'http://127.0.0.1:$sp','originRequest':{'noTLSVerify':True}},{'service':'http_status:404'}]}}))")
_c PUT "/accounts/$ai/tunnels/$ti/configurations" "$ig" > /dev/null
echo ">>> Binaries..."
mkdir -p "$D" && cd "$D"
if [[ ! -x ./xray ]]; then curl -fsSLo xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip; unzip -o xray.zip xray >/dev/null && chmod +x xray && rm xray.zip; fi
if [[ ! -x ./sing-box ]]; then
  ar=$(uname -m); case "$ar" in x86_64) sa=amd64;; aarch64) sa=arm64;; *) echo "Bad arch"; exit 1;; esac
  curl -fsSLo /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${sa}.tar.gz"
  tar -xzf /tmp/sb.tar.gz; mv "sing-box-linux-${sa}/sing-box" ./sing-box; chmod +x ./sing-box; rm -rf /tmp/sb.tar.gz "sing-box-linux-${sa}"
fi
if [[ ! -x /usr/local/bin/cloudflared ]]; then curl -fsSLo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; chmod +x /usr/local/bin/cloudflared; fi
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
=== XRAY ===
$xu
=== SB ===
$su
EE
echo ""
echo "=== DONE ==="
echo "Xray: $xh:443  UUID=$XRAY_UUID"; echo "$xu"
echo "SB:   $sh:443  UUID=$SB_UUID"; echo "$su"
echo "Uninstall: sudo bash scripts/uninstall.sh --tok TOKEN --tid $ti --aid $ai"
