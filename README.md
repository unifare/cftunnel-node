# CF Tunnel Proxy

一键部署 xray + sing-box + Cloudflare Tunnel。**只需一个 CF API Token。**

## 架构

```
客户端 --TLS--> Cloudflare CDN --Tunnel--> VPS
                                            |-- 127.0.0.1:20001 xray (VLESS+XHTTP)
                                            +-- 127.0.0.1:20002 sing-box (VLESS+WS)
```

全程 API 自动化，零交互。无需开放端口，隐藏真实 IP。

## 快速开始

```bash
sudo bash scripts/install.sh --tok <CF_API_TOKEN> --zone example.com
```

脚本自动完成：创建 Tunnel → DNS CNAME → Ingress 路由 → 下载二进制 → 生成密钥 → systemd 部署。

### 参数

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `--tok` | yes | — | CF API Token |
| `--zone` | yes | — | CF 托管的域名 |
| `--xray-host` | no | `xray.<zone>` | Xray 节点域名 |
| `--sb-host` | no | `sb.<zone>` | Sing-box 节点域名 |
| `--xray-port` | no | `20001` | Xray 本地端口 |
| `--sb-port` | no | `20002` | SB 本地端口 |
| `--tunnel-name` | no | 随机 | Tunnel 名称 |

### CF Token 权限

- Account → Cloudflare Tunnel: Edit
- Zone → DNS: Edit

创建：https://dash.cloudflare.com/profile/api-tokens

## 协议

| 节点 | 协议 | 传输 | 路径 |
|------|------|------|------|
| xray | VLESS | XHTTP | `/xray` |
| sing-box | VLESS | WebSocket | `/sing940` |

## 管理

```bash
bash scripts/status.sh                        # 状态
sudo bash scripts/uninstall.sh                 # 本地卸载
sudo bash scripts/uninstall.sh --tok T --tid ID --aid ACCT  # 含 CF 清理
```

## 客户端

| 平台 | 客户端 |
|------|--------|
| iOS | Shadowrocket |
| Android | v2rayNG |
| Windows | v2rayN |
| macOS | V2RayXS |

安装完成后输出的 vless:// 链接直接导入即可。

## 要求

- Debian/Ubuntu x86_64, root
- CF 账号 + 域名 DNS 托管在 CF
