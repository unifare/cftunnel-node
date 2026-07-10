#!/usr/bin/env bash
set -euo pipefail
t="";ti="";ai=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --tok)       t="\$2"; shift 2 ;;
    --tid)       ti="\$2"; shift 2 ;;
    --aid)       ai="\$2"; shift 2 ;;
    *) echo "Unknown: \$1"; exit 1 ;;
  esac
done
[[ \$EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
echo "Stopping..."
systemctl disable --now xray-proxy singbox-proxy cloudflared-proxy 2>/dev/null || true
echo "Removing units..."
rm -f /etc/systemd/system/{xray-proxy,singbox-proxy,cloudflared-proxy}.service
systemctl daemon-reload
echo "Removing cloudflared..."
rm -rf /etc/cloudflared /usr/local/bin/cloudflared
echo "Removing configs..."
rm -f /opt/proxy/{xray_keys.env,sb_keys.env,config.json,sb-config.json,clients.txt}
if [[ -n "\${t:-}" && -n "\${ti:-}" && -n "\${ai:-}" ]]; then
  echo "Deleting CF Tunnel: \$ti"
  curl -sf -X DELETE -H "Authorization: Bearer \${t}"     "https://api.cloudflare.com/client/v4/accounts/\${ai}/tunnels/\${ti}"     > /dev/null && echo "  Deleted" || echo "  Failed"
fi
echo ""; echo "Done. Binaries kept."
echo "Full remove: rm -rf /opt/proxy"
