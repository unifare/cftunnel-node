#!/usr/bin/env bash
# Show proxy deployment status
set -e

D=/opt/proxy
echo "=== Services ==="
for s in singbox-proxy cloudflared-proxy; do
  status=$(systemctl is-active $s 2>/dev/null || echo "inactive")
  printf "  %-22s %s\n" "$s" "$status"
done

echo ""
echo "=== Ports ==="
ss -lntp 2>/dev/null | grep -E ':(20001|20002)' | awk '{print "  "$4" -> "$6}' || echo "  (none)"

echo ""
if test -f "$D/.state"; then
  . "$D/.state"
  echo "=== Deployment ==="
  echo "  Zone:     $zone_name"
  echo "  Tunnel:   $tunnel_name"
  echo ""
  test -f "$D/clients.txt" && cat "$D/clients.txt"
fi
