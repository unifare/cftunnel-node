#!/usr/bin/env bash
# 卸载：停服务 + 删 unit + 删配置和凭据（保留核心二进制方便重装）
# 用法: sudo bash uninstall.sh [tunnel-name]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "❌ 请用 root 跑"; exit 1; fi
TUNNEL_NAME="${1:-}"

echo "→ 停服务"
systemctl disable --now xray-proxy singbox-proxy cloudflared-proxy 2>/dev/null || true

echo "→ 删 systemd 单元"
rm -f /etc/systemd/system/xray-proxy.service
rm -f /etc/systemd/system/singbox-proxy.service
rm -f /etc/systemd/system/cloudflared-proxy.service
systemctl daemon-reload

echo "→ 删 cloudflared 配置"
rm -rf /etc/cloudflared
rm -f /usr/local/bin/cloudflared

echo "→ 删凭据"
rm -f /opt/proxy/xray_keys.env /opt/proxy/sb_pass.env /opt/proxy/config.json /opt/proxy/sb-config.json /opt/proxy/sb.crt /opt/proxy/sb.key
rm -f /opt/proxy/scripts/{install,status,uninstall}.sh

echo ""
echo "✅ 卸载完成（保留 xray/sing-box 二进制在 /opt/proxy/）"
echo "   彻底删: rm -rf /opt/proxy"