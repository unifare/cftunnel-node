#!/usr/bin/env bash
# 查看三服务状态和最新日志
set -e
echo "=== 服务状态 ==="
for svc in xray-proxy singbox-proxy cloudflared-proxy; do
  status=$(systemctl is-active $svc 2>/dev/null || echo "inactive")
  printf "  %-22s %s\n" "$svc" "$status"
done
echo ""
echo "=== 端口监听 ==="
ss -lntup 2>/dev/null | grep -E ':(20001|20002)' || echo "  (无)"
echo ""
echo "=== 最近 20 行日志 ==="
for svc in xray-proxy singbox-proxy cloudflared-proxy; do
  echo "--- $svc ---"
  journalctl -u $svc -n 20 --no-pager 2>/dev/null || echo "  (无日志)"
done