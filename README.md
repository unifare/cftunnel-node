# sing-box all-in-one proxy + CF Tunnel

一键部署 **5 协议**代理服务。只需一个 CF API Token。

## 协议

| 协议 | 端口 | 通道 | 说明 |
|------|------|------|------|
| VLESS + HTTPUpgrade | 20001 (内部) | CF Tunnel | CDN 友好，隐藏 IP |
| VLESS + WebSocket | 20002 (内部) | CF Tunnel | 同上 |
| Hysteria2 | 8443 | 直连 | 低延迟，UDP 友好 |
| TUIC | 8444 | 直连 | 多路复用 |
| Reality (VLESS) | 8445 | 直连 | 抗封锁，伪装 TLS |

## 架构

```
客户端
├── Tunnel 通道（TLS）
│   └── CF CDN → CF Tunnel → 127.0.0.1:20001 XHTTP
│                           → 127.0.0.1:20002 WS
└── 直连通道（QUIC/TLS）
    ├── VPS:8443  Hysteria2
    ├── VPS:8444  TUIC
    └── VPS:8445  Reality
```

## 快速开始

```bash
sudo bash scripts/install.sh --tok <CF_API_TOKEN>
```

## CF API Token

https://dash.cloudflare.com/profile/api-tokens → 自定义令牌：

| 权限 | 资源 |
|------|------|
| Cloudflare Tunnel — Edit | 账户 |
| DNS — Edit | 区域 |

## 参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `--tok` | (必填) | CF API Token |
| `--reality-sni` | `swift.com` | Reality 伪装域名 |
| `--fresh` | | 强制重建（域名会变） |

## 管理

```bash
sudo bash scripts/uninstall.sh              # 卸载（含 CF 清理）
sudo bash scripts/install.sh --tok <T>      # 更新（复用域名）
sudo bash scripts/install.sh --tok <T> --fresh  # 重建
```

## 防火墙

脚本自动开放 8443-8445 (tcp+udp)。内部端口 20001-20002 只绑 127.0.0.1。

## 要求

- Debian/Ubuntu x86_64, root
- CF 账号 + 域名 DNS 托管在 CF
- 公网 IP（直连协议需要）
