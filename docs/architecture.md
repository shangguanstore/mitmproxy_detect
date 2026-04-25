# 实现原理：跨 GFW 流量捕获

## 背景与目标

目标：开发机（国内，macOS + Clash）访问 `api.anthropic.com` 的流量，全部被服务端 mitmproxy 捕获并记录，不使用 SSH 隧道，配置简单可复用。

核心难点：GFW 通过 **SNI 嗅探**封锁 `api.anthropic.com`——TLS ClientHello 里的 SNI 字段是明文，GFW 看到就 RST。直接在国内访问该域名不可能绕过。

---

## 网络拓扑

```
┌─────────────────────────────────────────────────────────────────────┐
│  开发机（国内，macOS）                                               │
│                                                                     │
│  Claude Code / Python SDK / curl                                    │
│       │ HTTPS_PROXY=http://127.0.0.1:7897                           │
│       ▼                                                             │
│  Clash（7897，本地混合代理）                                         │
│       │ 规则匹配 api.anthropic.com → mitmproxy-relay                │
│       │                                                             │
│       │ 建立 TLS 连接（SNI=hxe.7hu.cn）                            │
│       │ 在 TLS 内发送：CONNECT api.anthropic.com:443                │
└───────┼─────────────────────────────────────────────────────────────┘
        │
        │ ← GFW 只看到 SNI=hxe.7hu.cn，放行 →
        │
┌───────┼─────────────────────────────────────────────────────────────┐
│  服务器（公网，114.132.245.209）                                     │
│       │                                                             │
│       ▼  :8444（安全组直接开放）                                     │
│  tls_proxy.py                                                       │
│       │ 终止外层 TLS（tls_proxy.crt）                               │
│       │ 透明转发裸 TCP                                               │
│       ▼  :8081                                                      │
│  mitmproxy（upstream 模式）                                          │
│       │ 接收 CONNECT api.anthropic.com:443                          │
│       │ 动态签发 api.anthropic.com 的伪造证书                        │
│       │ 解密后写入 logs/traffic.jsonl                                │
│       ▼  :7890                                                      │
│  Clash（服务端，出口代理）                                           │
│       │ 路由到机场 / 真实网络                                        │
│       ▼                                                             │
│  api.anthropic.com（真实目标）                                       │
│                                                                     │
│  Web 查看器（:8888）─────────────── /ca     下载 mitmproxy CA 证书  │
│       读取 logs/traffic.jsonl        /setup  开发机一键安装命令      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 方案：HTTPS CONNECT over TLS

将 HTTP CONNECT 请求藏进 TLS 隧道里，让 GFW 只看到外层 TLS 的 SNI（`hxe.7hu.cn`，不被封锁），看不到里面 CONNECT 的目标（`api.anthropic.com`）。

完整数据路径：

```
Claude Code
    ↓ HTTP CONNECT api.anthropic.com:443（发往本地 Clash）
Clash（7897）
    ↓ 建立 TLS 连接到 114.132.245.209:8444，SNI=hxe.7hu.cn
    ↓ 在 TLS 内发送 CONNECT api.anthropic.com:443
[GFW 只看到 SNI=hxe.7hu.cn，放行]
    ↓
tls_proxy.py（8444）终止外层 TLS，转发原始 TCP
    ↓
mitmproxy（8081，upstream 模式）
    ↓ 拦截 TLS，动态签发 api.anthropic.com 的伪造证书
    ↓ 解密明文，记录请求/响应到 traffic.jsonl
    ↓
服务器 Clash（7890）→ api.anthropic.com（真实请求）
```

---

## 各组件说明

### 1. `tls_proxy.py`（服务端，:8444）

监听 8444 端口，完成两件事：

- **终止外层 TLS**：用 `hxe.7hu.cn` 的证书（`tls_proxy.crt`，由 mitmproxy CA 签发），接受客户端的 TLS 握手
- **透明转发**：TLS 解密后，将原始 TCP 字节流双向 relay 给 mitmproxy:8081

```
客户端 TLS ──→ tls_proxy:8444 ──→ 裸 TCP ──→ mitmproxy:8081
```

mitmproxy 本身不支持"接受 HTTPS 入站再处理 HTTP CONNECT"的组合，tls_proxy 做完 TLS 终止后，mitmproxy 只看到普通的 HTTP CONNECT 请求。

> **端口说明**：8444 由云服务器安全组直接开放，不再需要 iptables 端口重定向。

### 2. mitmproxy（服务端，:8081）

```bash
mitmdump -s traffic_logger.py \
  --listen-port 8081 \
  --mode upstream:http://127.0.0.1:7890 \
  --set ssl_insecure=true
```

- **upstream 模式**：收到 CONNECT 后，把请求转发给服务器本地的 Clash（7890），由 Clash 出国访问真实目标
- **TLS 拦截**：对客户端动态签发目标域名的伪造证书（由 mitmproxy CA 签发），从而解密 HTTPS 内容
- **ssl_insecure**：允许向上游连接时跳过证书验证

### 3. `traffic_logger.py`（mitmproxy 插件）

随 mitmproxy 加载，监听三个钩子：

| 钩子 | 触发时机 | 动作 |
|------|----------|------|
| `request` | 收到完整请求 | 暂存请求字段，relay 模式下直接拦截返回 |
| `response` | 收到完整响应 | 合并请求+响应，追加写入 JSONL |
| `error` | 连接失败 | 记录错误信息，CONNECT 失败也单独记录 |

支持两种运行模式：

- **正向代理模式**（默认）：记录后透传给上游
- **Relay 模式**（`MITM_RELAY_MODE=1` 或 `config.yaml` 中 `relay_mode: true`）：拦截请求，返回空响应，不转发上游

### 4. Clash 配置（开发机）

Clash Verge 用户将以下内容写入 Merge.yaml，订阅更新后依然生效：

```yaml
prepend-proxies:
  - name: mitmproxy-relay
    type: http          # HTTP CONNECT 代理
    server: 114.132.245.209
    port: 8444          # 直连安全组开放端口
    tls: true           # 外层 TLS（隐藏 CONNECT 目标，绕过 GFW）
    skip-cert-verify: true
    sni: hxe.7hu.cn    # GFW 看到的 SNI

prepend-rules:
  - DOMAIN,api.anthropic.com,mitmproxy-relay  # 必须是第一条
```

**`skip-cert-verify: true` 说明**：tls_proxy.crt 由 mitmproxy CA 自签，不在系统信任链内，Clash 跳过验证才能建立外层 TLS。  
**Clash TUN 用户额外配置**：需将服务器 IP 加入 `route-exclude-address`，否则 gvisor 在本地完成 TCP 握手但不实际转发数据。

```yaml
tun:
  route-exclude-address:
    - 114.132.245.209/32
```

> **Merge.yaml 处理说明**：`prepend-proxies` / `prepend-rules` 是 Clash Verge 应用层语法，mihomo 核心本身不识别。直接调用 mihomo API reload 配置时，需确保 proxy 在 `proxies:` 节、rule 在 `rules:` 节。`mitmproxy_capture.sh` 会同时写两处。

### 5. TLS 证书链

```
mitmproxy CA（~/.mitmproxy/mitmproxy-ca.pem，含私钥，勿外传）
    ├── tls_proxy.crt（hxe.7hu.cn）  ← tls_proxy.py 使用，外层 TLS
    └── 动态签发 api.anthropic.com 等证书  ← mitmproxy MITM 时使用
```

客户端需要信任 mitmproxy CA，才能接受 mitmproxy 伪造的内层证书（`api.anthropic.com`）。外层证书（`hxe.7hu.cn`）由 Clash 的 `skip-cert-verify: true` 跳过验证，无需安装。

---

## 开发机证书安装

mitmproxy 做 HTTPS MITM 时，客户端会收到由 mitmproxy CA 签发的伪造证书。Node.js（Claude Code）和浏览器需信任该 CA 才能正常工作。

Web 查看器提供了两个便捷端点：

| 路径 | 说明 |
|------|------|
| `http://服务器IP:8888/ca` | 下载 mitmproxy CA 证书（PEM 格式） |
| `http://服务器IP:8888/setup` | 含 macOS / Linux 一键安装命令的页面 |

**macOS**（在开发机执行一次）：

```bash
curl -s http://服务器IP:8888/ca -o /tmp/mitmproxy-ca.pem && \
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/mitmproxy-ca.pem && \
echo 'export NODE_EXTRA_CA_CERTS=/tmp/mitmproxy-ca.pem' >> ~/.zshrc
```

**Linux**（在开发机执行一次）：

```bash
curl -s http://服务器IP:8888/ca | sudo tee /usr/local/share/ca-certificates/mitmproxy-ca.crt > /dev/null && \
sudo update-ca-certificates && \
echo 'export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mitmproxy-ca.crt' >> ~/.bashrc
```

> `NODE_EXTRA_CA_CERTS` 是 Node.js 专用环境变量，用于追加信任的 CA 证书。Node.js 默认不读取系统证书库，因此即使系统已安装，也需要单独设置此变量。安装后重启终端生效。

---

## 为其他开发机添加捕获

1. 在 Clash Verge 的 Merge.yaml 中添加 proxy + rule（见上方配置）
2. 在开发机终端执行 `http://服务器IP:8888/setup` 页面中的安装命令
3. 重启终端，设置 `HTTPS_PROXY=http://127.0.0.1:7897`（或 Claude Code 对应代理端口）
4. 验证：`curl --proxy http://127.0.0.1:7897 -v https://api.anthropic.com/v1/models 2>&1 | grep issuer`
   - 期望输出包含：`issuer: CN=mitmproxy; O=mitmproxy`

---

## 端口全景

| 端口 | 位置 | 说明 |
|------|------|------|
| 8444 | 服务器（公网，安全组开放） | 对外入口，tls_proxy.py 监听，TLS 终止 |
| 8081 | 服务器（本地） | mitmproxy，流量捕获与记录 |
| 7890 | 服务器（本地） | Clash 出口代理（机场） |
| 8888 | 服务器（本地/可对外） | Web 查看器，含 /ca、/setup 端点 |
| 7897 | 开发机（本地） | Clash 混合代理端口 |

---

## Relay 模式（可选）

`start_relay.sh` 启动另一套 mitmproxy 实例，用于**拦截不转发**的场景（如测试、mock）：

- HTTP relay：监听 8082（iptables 将 80 重定向到此）
- HTTPS relay：监听 8083（iptables 将 443 重定向到此）
- 开发机修改 hosts 将目标域名指向服务器 IP，流量进入 relay 后返回空响应并记录

config.yaml 中 `relay_mode: false`（默认），正常捕获模式下不涉及此功能。
