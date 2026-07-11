# CF Tunnel Proxy

一键部署 xray + sing-box + Cloudflare Tunnel。**只需一个 CF API Token。**

## 快速开始

```bash
sudo bash scripts/install.sh --tok <CF_API_TOKEN>
```

脚本自动：检测域名 → 创建 Tunnel → DNS CNAME → Ingress 路由 → 下载二进制 → systemd 部署。

## CF API Token

### 创建步骤

1. 打开 https://dash.cloudflare.com/profile/api-tokens
2. 点击 **创建令牌** → **自定义令牌**
3. 权限设置：

| 权限 | 资源 |
|------|------|
| **Cloudflare Tunnel** — Edit | 包含 — 账户 |
| **DNS** — Edit | 包含 — 区域 |

4. **区域资源** 和 **账户资源** 都选「包括 — 所有」
5. 点「继续到摘要」→「创建令牌」→ **立即复制**（刷新后不可见）

### 注意

- 必须是 **API Token**（`Bearer` 认证），不是 Global API Key
- 令牌只在创建时显示一次，刷新页面就没了

## 参数

| 参数 | 必填 | 默认 | 说明 |
|------|------|------|------|
| `--tok` | ✅ | — | CF API Token |
| `--xray-host` | | 随机.域名 | Xray 节点域名 |
| `--sb-host` | | 随机.域名 | Sing-box 节点域名 |
| `--xray-port` | | `20001` | Xray 本地端口 |
| `--sb-port` | | `20002` | Sing-box 本地端口 |
| `--tunnel-name` | | 随机 | Tunnel 名称 |

域名自动取 CF 账号下第一个活跃的。hostname 用随机 8 位前缀。

## 架构

```
客户端 --TLS--> Cloudflare CDN --Tunnel--> VPS
                                            |-- :20001 xray (VLESS+XHTTP)
                                            +-- :20002 sing-box (VLESS+WS)
```

| 节点 | 协议 | 传输 | 路径 |
|------|------|------|------|
| xray | VLESS | XHTTP | `/xray` |
| sing-box | VLESS | WebSocket | `/sing940` |

## 管理

```bash
bash scripts/status.sh
sudo bash scripts/uninstall.sh
sudo bash scripts/uninstall.sh --tok TOKEN --tid ID --aid ACCT   # 含 CF 清理
```

## 要求

- Debian/Ubuntu x86_64, root
- CF 账号 + 域名 DNS 托管在 CF
