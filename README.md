# Proxy Install Scripts

一键部署 xray + sing-box + Cloudflare Tunnel 代理服务。

## 架构

```
客户端 ──TLS──▶ Cloudflare CDN ──Cloudflare Tunnel──▶ VPS
                                                       ├── 127.0.0.1:20001  xray (VLESS + XHTTP)
                                                       └── 127.0.0.1:20002  sing-box (VLESS + WebSocket)
```

两个节点都走 CF Tunnel，无需开放 VPS 端口，隐藏真实 IP。

## 使用

```bash
sudo bash scripts/install.sh
```

脚本交互式询问：
- Cloudflare Tunnel Token
- Tunnel 名称
- Xray 客户端域名
- Sing-box 客户端域名

## 服务管理

```bash
# 状态
bash scripts/status.sh

# 启停
systemctl start/stop/restart xray-proxy singbox-proxy cloudflared-proxy

# 卸载
sudo bash scripts/uninstall.sh
```

## 要求

- Debian/Ubuntu x86_64
- Cloudflare 账号（已创建 Named Tunnel）
- 域名 DNS 在 Cloudflare 管理

## 协议

| 节点 | 协议 | 传输 | 路径 |
|------|------|------|------|
| xray | VLESS | XHTTP (SplitHTTP) | `/xray` |
| sing-box | VLESS | WebSocket | `/sing940` |
