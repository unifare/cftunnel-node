# sing-box all-in-one proxy

一键部署 **5 协议**代理服务。只需一个 CF API Token。

## 协议

| 协议 | 端口 | 通道 | 适用 |
|------|------|------|------|
| VLESS + HTTPUpgrade | 20001（内部） | CF Tunnel | 高隐匿，CDN 友好 |
| VLESS + WebSocket | 20002（内部） | CF Tunnel | 同上，兼容性强 |
| Hysteria2 | 8443 | 直连 | 低延迟，UDP/游戏 |
| TUIC | 8444 | 直连 | 多路复用，弱网优化 |
| Reality | 8445 | 直连 | 抗封锁，伪装 TLS |

## 快速开始

```bash
sudo bash scripts/install.sh --tok <CF_API_TOKEN>
```

部署完成后直接输出 5 条链接 + 订阅地址。

### 行为

| 场景 | 命令 | 结果 |
|------|------|------|
| 首次部署 | `install.sh --tok T` | 创建 Tunnel + DNS → 部署 |
| 更新配置 | `install.sh --tok T` | 复用域名，只刷新配置 |
| 重建 | `install.sh --tok T --fresh` | 删旧建新，域名随机换 |

## 订阅

部署后自动启动订阅服务，输出格式：

| 客户端 | 订阅 URL |
|--------|----------|
| v2rayN / v2rayNG | `http://<VPS_IP>:9091/sub` |
| Shadowrocket | 同上 |
| Clash Meta | `http://<VPS_IP>:9091/clash` |
| Clash Verge | 同上 |

Clash 配置含 Auto（自动测速）、Tunnel、Direct 三个策略组。

## CF API Token

https://dash.cloudflare.com/profile/api-tokens → 自定义令牌：

| 权限 | 资源 |
|------|------|
| Cloudflare Tunnel — Edit | 账户 |
| DNS — Edit | 区域 |

## 参数

| 参数 | 默认 | 说明 |
|------|------|------|
| `--tok` | 必填 | CF API Token |
| `--reality-sni` | `swift.com` | Reality 伪装 SNI |
| `--fresh` | | 强制重建 |

## 架构

```
客户端
├── Tunnel 通道（TLS，CF CDN）
│   └── CF Tunnel → 127.0.0.1:20001 XHTTP
│                → 127.0.0.1:20002 WS
└── 直连通道（QUIC/TLS，直连 VPS）
    ├── :8443 Hysteria2
    ├── :8444 TUIC
    └── :8445 Reality
```

## 管理

```bash
sudo bash scripts/uninstall.sh    # 卸载（含 CF 资源清理）
systemctl status singbox-proxy     # 服务状态
journalctl -u singbox-proxy -f     # 实时日志
```

## 要求

- Debian/Ubuntu x86_64, root
- CF 账号，域名 DNS 托管在 CF
- 公网 IP（直连协议需要）
