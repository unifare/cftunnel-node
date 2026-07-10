#!/usr/bin/env bash
# 一键安装 xray + sing-box + cloudflared（固定 Named Tunnel）
# 两个节点都走 CF Tunnel，使用 TCP-based 协议（CF Tunnel 不支持 UDP）：
#   - xray:      VLESS + XHTTP + TLS     (127.0.0.1:20001)
#   - sing-box:  VLESS + WebSocket + TLS (127.0.0.1:20002)
#
# 用法: sudo bash install.sh
#  脚本会交互式询问：tunnel token、tunnel 名、xray hostname、sing-box hostname
set -euo pipefail

PROXY_DIR=/opt/proxy

if [[ $EUID -ne 0 ]]; then echo "❌ 请用 root 跑"; exit 1; fi
if [[ ! -t 0 ]]; then
  echo "❌ 需要交互输入，请在终端跑"
  exit 1
fi
read -rp "Cloudflare Tunnel token（eyJh 开头的字符串）: " TUNNEL_TOKEN
read -rp "Tunnel 名称（CF 后台显示）: " TUNNEL_NAME
read -rp "Xray 客户端域名（CF Public Hostname，如 xray.example.com）: " XRAY_HOST
read -rp "Sing-box 客户端域名（如 sb.example.com）: " SB_HOST
read -rp "Xray 本地监听端口 [默认 20001]: " XRAY_PORT
read -rp "Sing-box 本地监听端口 [默认 20002]: " SB_PORT
XRAY_PORT=${XRAY_PORT:-20001}
SB_PORT=${SB_PORT:-20002}
[[ -z "$TUNNEL_TOKEN" || -z "$TUNNEL_NAME" || -z "$XRAY_HOST" || -z "$SB_HOST" ]] && {
  echo "❌ 四项都不能为空"; exit 1; }
[[ ! "$XRAY_PORT" =~ ^[0-9]+$ || "$XRAY_PORT" -lt 1 || "$XRAY_PORT" -gt 65535 ]] && {
  echo "❌ Xray 端口非法"; exit 1; }
[[ ! "$SB_PORT" =~ ^[0-9]+$ || "$SB_PORT" -lt 1 || "$SB_PORT" -gt 65535 ]] && {
  echo "❌ Sing-box 端口非法"; exit 1; }
[[ "$XRAY_PORT" == "$SB_PORT" ]] && {
  echo "❌ 两个端口不能相同"; exit 1; }
echo ""
echo "→ Tunnel:      $TUNNEL_NAME"
echo "→ Xray 域名:   $XRAY_HOST → 127.0.0.1:${XRAY_PORT} (VLESS+XHTTP+TLS, path=/xray)"
echo "→ Sing-box:    $SB_HOST → 127.0.0.1:${SB_PORT} (VLESS+WS+TLS,   path=/sing940)"
echo ""
mkdir -p "$PROXY_DIR"
cd "$PROXY_DIR"

# 1. 下载核心（已存在则跳过）
if [[ ! -x ./xray ]]; then
  curl -fsSL -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
  unzip -o xray.zip xray >/dev/null && chmod +x xray && rm xray.zip
fi
if [[ ! -x ./sing-box ]]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  SB_ARCH=amd64 ;;
    aarch64) SB_ARCH=arm64 ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
  esac
  curl -fsSL -o /tmp/sb.tar.gz \
    "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-linux-${SB_ARCH}.tar.gz"
  tar -xzf /tmp/sb.tar.gz
  mv "sing-box-linux-${SB_ARCH}/sing-box" ./sing-box
  chmod +x ./sing-box
  rm -rf /tmp/sb.tar.gz "sing-box-linux-${SB_ARCH}"
fi
if [[ ! -x /usr/local/bin/cloudflared ]]; then
  curl -fsSL -o /usr/local/bin/cloudflared \
    https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  chmod +x /usr/local/bin/cloudflared
fi

# 2. 生成凭据（已存在则保留；删 xray_keys.env / sb_keys.env 即重生成）
if [[ ! -f $PROXY_DIR/xray_keys.env ]]; then
  XRAY_UUID=$(./xray uuid)
  cat > $PROXY_DIR/xray_keys.env <<EOF
XRAY_UUID=$XRAY_UUID
EOF
fi
# shellcheck disable=SC1091
source $PROXY_DIR/xray_keys.env

if [[ ! -f $PROXY_DIR/sb_keys.env ]]; then
  SB_UUID=$(./sing-box generate uuid)
  echo "SB_UUID=$SB_UUID" > $PROXY_DIR/sb_keys.env
fi
# shellcheck disable=SC1091
source $PROXY_DIR/sb_keys.env

# 3. xray 配置 (VLESS + XHTTP + TLS) → 127.0.0.1:${XRAY_PORT}
# XHTTP = SplitHTTP (POST 分片上传)，CDN 友好；过 CF Tunnel 必须用 TLS + 真实 SNI
cat > $PROXY_DIR/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1", "port": ${XRAY_PORT}, "protocol": "vless",
    "settings": {
      "clients": [{"id": "$XRAY_UUID"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": {
        "path": "/xray"
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

# 4. sing-box 配置 (VLESS + WebSocket + TLS) → 127.0.0.1:${SB_PORT}
# WebSocket 是最兼容的 CDN 协议，sing-box 完整支持
cat > $PROXY_DIR/sb-config.json <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [{
    "type": "vless",
    "listen": "127.0.0.1",
    "listen_port": ${SB_PORT},
    "users": [{"uuid": "$SB_UUID", "name": "client"}],
    "transport": {
      "type": "ws",
      "path": "/sing940"
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
EOF

# 5. cloudflared 配置 + token 落盘
mkdir -p /etc/cloudflared
echo "$TUNNEL_TOKEN" > /etc/cloudflared/$TUNNEL_NAME.token
chmod 600 /etc/cloudflared/$TUNNEL_NAME.token

# XHTTP 必须走 HTTP ingress（XHTTP = HTTP POST 分片）
# WebSocket 也走 HTTP ingress（CF Tunnel 会自动 Upgrade）
cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_NAME
metrics: 127.0.0.1:20000
protocol: quic
no-autoupdate: true
ingress:
  - hostname: $XRAY_HOST
    service: http://127.0.0.1:${XRAY_PORT}
    originRequest: { noTLSVerify: true }
  - hostname: $SB_HOST
    service: http://127.0.0.1:${SB_PORT}
    originRequest: { noTLSVerify: true }
  - service: http_status:404
EOF

# 6. systemd 单元
cat > /etc/systemd/system/xray-proxy.service <<EOF
[Unit]
Description=Xray Proxy (VLESS+XHTTP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROXY_DIR
ExecStart=$PROXY_DIR/xray run -c $PROXY_DIR/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/singbox-proxy.service <<EOF
[Unit]
Description=Sing-box Proxy (VLESS+WS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$PROXY_DIR
ExecStart=$PROXY_DIR/sing-box run -c $PROXY_DIR/sb-config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cloudflared-proxy.service <<EOF
[Unit]
Description=Cloudflare Tunnel ($TUNNEL_NAME)
After=network-online.target xray-proxy.service singbox-proxy.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run $TUNNEL_NAME
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# 7. 启用并启动
systemctl daemon-reload
systemctl enable --now xray-proxy singbox-proxy cloudflared-proxy

echo ""
echo "✅ 安装完成"
echo "── Xray (VLESS + XHTTP + TLS) ──"
echo "  域名: $XRAY_HOST:443"
echo "  端口: 127.0.0.1:${XRAY_PORT}"
echo "  UUID: $XRAY_UUID"
echo "  Path: /xray"
echo ""
echo "── Sing-box (VLESS + WebSocket + TLS) ──"
echo "  域名: $SB_HOST:443"
echo "  端口: 127.0.0.1:${SB_PORT}"
echo "  UUID: $SB_UUID"
echo "  Path: /sing940"
echo ""

# 生成 v2ray 分享 URL（v2rayN/v2rayNG/Shadowrocket/Clash.Meta 全认）
# XHTTP+TLS 的关键：security=tls + SNI 必须是真实域名（CF 用 SNI 路由）
XRAY_URI="vless://${XRAY_UUID}@${XRAY_HOST}:443?encryption=none&security=tls&sni=${XRAY_HOST}&type=xhttp&host=${XRAY_HOST}&path=%2Fxray&fp=chrome&alpn=h2,http/1.1#${TUNNEL_NAME}-XRAY"
SB_URI="vless://${SB_UUID}@${SB_HOST}:443?encryption=none&security=tls&sni=${SB_HOST}&type=ws&host=${SB_HOST}&path=%2Fsing940#${TUNNEL_NAME}-WS"

cat > $PROXY_DIR/clients.txt <<EOF
=== XRAY (VLESS+XHTTP+TLS) ===
$XRAY_URI

=== SING-BOX (VLESS+WS+TLS) ===
$SB_URI
EOF

echo "── v2ray 分享地址（复制到客户端导入）──"
echo "$XRAY_URI"
echo ""
echo "$SB_URI"
echo ""
echo "  已存 $PROXY_DIR/clients.txt"
echo ""
echo "── 服务管理 ──"
echo "  systemctl status xray-proxy singbox-proxy cloudflared-proxy"
echo "  bash $PROXY_DIR/scripts/status.sh"