#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

# Read state
if test -f "$D/.state"; then
  ti=$(grep '^tunnel_id=' "$D/.state" | cut -d= -f2)
  ai=$(grep '^account_id=' "$D/.state" | cut -d= -f2)
  zi=$(grep '^zone_id=' "$D/.state" | cut -d= -f2)
  hosts=$(grep '^hosts=' "$D/.state" | cut -d= -f2)
fi

echo "Stopping services..."
systemctl disable --now xray-proxy singbox-proxy cloudflared-proxy 2>/dev/null || true
rm -f /etc/systemd/system/{xray-proxy,singbox-proxy,cloudflared-proxy}.service
systemctl daemon-reload

echo "Removing cloudflared..."
rm -rf /etc/cloudflared /usr/local/bin/cloudflared

echo "Removing configs..."
rm -f "$D"/{xray_keys.env,sb_keys.env,config.json,sb-config.json,clients.txt,.state}

# CF cleanup using state
if test -n "${ti:-}" -a -n "${ai:-}" -a -n "${zi:-}"; then
  echo ">>> CF cleanup: tunnel $ti"
  # Need token
  tok=""
  if test -f /tmp/_cftok_val; then
    tok=$(cat /tmp/_cftok_val)
  fi
  if test -z "$tok"; then
    read -rp "CF API Token for cleanup: " tok
  fi
  test -z "$tok" && { echo "No token, skipping CF cleanup."; exit 0; }

  printf "%s" "$tok" > /tmp/_cftok_val2
  cat > /tmp/_cf2.py << 'PY'
import sys,json,urllib.request
t=open('/tmp/_cftok_val2').read().strip()
a='Bearer '+t
def c(m,p,d=None):
    r=urllib.request.Request('https://api.cloudflare.com/client/v4'+p,method=m)
    r.add_header('Authorization',a);r.add_header('Content-Type','application/json')
    b=d.encode() if d else None
    try:return json.loads(urllib.request.urlopen(r,data=b,timeout=30))
    except urllib.error.HTTPError as e:return{'success':False,'errors':[{'message':str(e)}]}
r=c(sys.argv[1],sys.argv[2],sys.argv[3]if len(sys.argv)>3 else None);print(json.dumps(r))
PY

  cf() { python3 /tmp/_cf2.py "$1" "$2" "${3:-}"; }

  echo "  Deleting DNS records..."
  for h in $(echo "$hosts" | tr ',' ' '); do
    rid=$(cf GET "/zones/$zi/dns_records?type=CNAME&name=$h" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
    test -n "$rid" && { cf DELETE "/zones/$zi/dns_records/$rid" > /dev/null; echo "    $h deleted"; }
  done

  echo "  Deleting tunnel..."
  cf DELETE "/accounts/$ai/tunnels/$ti" > /dev/null && echo "    Tunnel deleted" || echo "    Tunnel already gone"

  rm -f /tmp/_cftok_val2 /tmp/_cf2.py
fi

echo ""
echo "Done. Binaries kept at $D/."
echo "Full remove: rm -rf $D"
