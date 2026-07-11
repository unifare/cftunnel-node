#!/usr/bin/env bash
set -euo pipefail
D=/opt/proxy
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

ti=""; ai=""; zi=""; hosts=""; tn=""; hp=""; tp=""; rp=""
if test -f "$D/.state"; then
  ti=$(grep '^tunnel_id=' "$D/.state" | cut -d= -f2)
  ai=$(grep '^account_id=' "$D/.state" | cut -d= -f2)
  zi=$(grep '^zone_id=' "$D/.state" | cut -d= -f2)
  hosts=$(grep '^hosts=' "$D/.state" | cut -d= -f2)
  tn=$(grep '^tunnel_name=' "$D/.state" | cut -d= -f2)
fi

echo "Stopping services..."
systemctl disable --now singbox-proxy cloudflared-proxy xray-proxy 2>/dev/null || true
rm -f /etc/systemd/system/{singbox-proxy,cloudflared-proxy,xray-proxy}.service
systemctl daemon-reload

echo "Removing cloudflared..."
rm -rf /etc/cloudflared /usr/local/bin/cloudflared

echo "Removing configs..."
rm -f "$D"/{sb_keys.env,xray_keys.env,sb-config.json,config.json,clients.txt,.state}
rm -f "$D"/{fullchain.pem,privkey.pem}

echo "Closing firewall ports..."
for port in 8443 8444 8445; do
  iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -p udp --dport $port -j ACCEPT 2>/dev/null || true
done
iptables -D INPUT -p tcp --dport 20001 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp --dport 20002 -j ACCEPT 2>/dev/null || true

if test -n "${ti:-}" -a -n "${ai:-}" -a -n "${zi:-}"; then
  echo ">>> CF cleanup: tunnel $ti"
  tok=""
  test -f /tmp/_cftok_val && tok=$(cat /tmp/_cftok_val) || true
  test -z "$tok" && read -rp "CF API Token: " tok
  test -z "$tok" && { echo "No token, skipping CF cleanup."; exit 0; }

  printf "%s" "$tok" > /tmp/_cftok_val2; chmod 600 /tmp/_cftok_val2

  cat > /tmp/_cf2.py << 'PY'
import sys, json, urllib.request
t = open('/tmp/_cftok_val2').read().strip()
a = 'Bearer ' + t
def c(m, p, d=None):
    req = urllib.request.Request('https://api.cloudflare.com/client/v4' + p, method=m)
    req.add_header('Authorization', a)
    req.add_header('Content-Type', 'application/json')
    body = d.encode() if d else None
    try:
        resp = urllib.request.urlopen(req, data=body, timeout=30)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return {'success': False, 'errors': [{'message': str(e)}]}
print(json.dumps(c(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)))
PY

  cf() { python3 /tmp/_cf2.py "$1" "$2" "${3:-}"; }

  echo "  Deleting DNS records..."
  for h in $(echo "$hosts" | tr ',' ' '); do
    rid=$(cf GET "/zones/$zi/dns_records?type=CNAME&name=$h" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)
    test -n "$rid" && { cf DELETE "/zones/$zi/dns_records/$rid" > /dev/null && echo "    $h"; } || echo "    $h (not found)"
  done

  echo "  Deleting tunnel..."
  cf DELETE "/accounts/$ai/tunnels/$ti" > /dev/null && echo "    $ti" || echo "    $ti (already gone)"

  rm -f /tmp/_cftok_val2 /tmp/_cf2.py
fi

echo ""
echo "Done. Binaries kept at $D/."
echo "Full remove: rm -rf $D"
