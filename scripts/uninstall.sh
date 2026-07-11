#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

ti=""; ai=""; zi=""; hosts=""; tn=""
if test -f "$D/.state"; then
  ti=$(grep '^tunnel_id=' "$D/.state" | cut -d= -f2)
  ai=$(grep '^account_id=' "$D/.state" | cut -d= -f2)
  zi=$(grep '^zone_id=' "$D/.state" | cut -d= -f2)
  hosts=$(grep '^hosts=' "$D/.state" | cut -d= -f2)
  tn=$(grep '^tunnel_name=' "$D/.state" | cut -d= -f2)
fi

echo "Stopping..."
systemctl disable --now singbox-proxy cloudflared-proxy xray-proxy 2>/dev/null || true
rm -f /etc/systemd/system/{singbox-proxy,cloudflared-proxy,xray-proxy}.service
systemctl daemon-reload

rm -rf /etc/cloudflared /usr/local/bin/cloudflared
rm -f "$D"/{sb_keys.env,xray_keys.env,sb-config.json,config.json,clients.txt,.state,fullchain.pem,privkey.pem}
rm -rf "$D"/sub

if test -n "${ti:-}" -a -n "${ai:-}" -a -n "${zi:-}"; then
  echo ">>> CF cleanup: $ti"
  tok=""
  test -f /tmp/_cftok_val && tok=$(cat /tmp/_cftok_val) || true
  test -z "$tok" && read -rp "CF Token: " tok
  test -z "$tok" && { echo "Skip."; exit 0; }

  printf "%s" "$tok" > /tmp/_cftok_val2; chmod 600 /tmp/_cftok_val2
  cat > /tmp/_cf2.py << 'PY'
import sys,json,urllib.request
t=open('/tmp/_cftok_val2').read().strip();a='Bearer '+t
def c(m,p,d=None):
    r=urllib.request.Request('https://api.cloudflare.com/client/v4'+p,method=m)
    r.add_header('Authorization',a);r.add_header('Content-Type','application/json')
    b=d.encode() if d else None
    try:return json.loads(urllib.request.urlopen(r,data=b,timeout=30).read())
    except urllib.error.HTTPError as e:return{'success':False}
r=c(sys.argv[1],sys.argv[2],sys.argv[3]if len(sys.argv)>3 else None);print(json.dumps(r))
PY
  cf() { python3 /tmp/_cf2.py "$1" "$2" "${3:-}"; }

  for h in $(echo "$hosts" | tr ',' ' '); do
    rid=$(cf GET "/zones/$zi/dns_records?type=CNAME&name=$h" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['result'][0]['id']if d.get('result')else'')" 2>/dev/null)
    test -n "$rid" && { cf DELETE "/zones/$zi/dns_records/$rid" > /dev/null && echo "  DNS: $h"; }
  done
  cf DELETE "/accounts/$ai/tunnels/$ti" > /dev/null && echo "  Tunnel deleted"
  rm -f /tmp/_cftok_val2 /tmp/_cf2.py
fi
echo "Done. rm -rf $D to fully remove."
