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
│       │ 通过 Clash TUN 透明拦截（或 HTTPS_PROXY=127.0.0.1:7897）   │
│       ▼                                                             │
│  Clash（7897，本地混合代理 + TUN 模式）                             │
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
    ↓ HTTPS 请求 api.anthropic.com（通过 Clash TUN 透明拦截）
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

> **端口说明**：8444 由云服务器安全组直接开放，不需要 iptables 端口重定向。

端口由环境变量控制，默认值：

```bash
TLS_PROXY_PORT=8444   # 对外监听端口
UPSTREAM_PORT=8081    # 转发目标（mitmproxy）
```

### 2. mitmproxy（服务端，:8081）

```bash
mitmdump -s traffic_logger.py \
  --listen-port 8081 \
  --mode upstream:http://127.0.0.1:7890 \
  --set ssl_insecure=true \
  --set termlog_verbosity=warn
```

- **upstream 模式**：收到 CONNECT 后，把请求转发给服务器本地的 Clash（7890），由 Clash 出国访问真实目标
- **TLS 拦截**：对客户端动态签发目标域名的伪造证书（由 mitmproxy CA 签发），从而解密 HTTPS 内容
- **ssl_insecure**：允许向上游连接时跳过证书验证

上游代理地址读取自 `config.yaml` 的 `upstream_proxy` 字段，留空则直连。

### 3. `traffic_logger.py`（mitmproxy 插件）

随 mitmproxy 加载，监听三个钩子：

| 钩子 | 触发时机 | 动作 |
|------|----------|------|
| `request` | 收到完整请求 | 暂存请求字段；relay 模式下直接拦截返回 |
| `response` | 收到完整响应 | 合并请求+响应，追加写入 JSONL |
| `error` | 连接失败 | 记录错误信息，CONNECT 失败也单独记录 |

支持两种运行模式：

- **正向代理模式**（默认）：记录后透传给上游
- **Relay 模式**（`MITM_RELAY_MODE=1` 或 `config.yaml` 中 `relay_mode: true`）：拦截请求，返回空响应，不转发上游

JSONL 每条记录字段：`id`、`timestamp`、`datetime`、`host`、`path`、`url`、`method`、`request_headers`、`request_body`、`request_size`、`status_code`、`error`、`response_headers`、`response_body`、`content_type`、`duration_ms`、`response_size`。

### 4. `mitmproxy_capture.sh`（开发机 Clash 配置管理）

> **脚本放在服务器上**，通过 SSH 管道在 Mac 开发机上执行：
>
> ```bash
> # 在服务器上执行（SSH 到 Mac 并注入脚本）
> ssh -p 2222 sgyy@localhost 'bash -s install' < mitmproxy_capture.sh
> ssh -p 2222 sgyy@localhost 'bash -s status'  < mitmproxy_capture.sh
> ssh -p 2222 sgyy@localhost 'bash -s uninstall' < mitmproxy_capture.sh
> ```

三个子命令：

| 命令 | 作用 |
|------|------|
| `install` | 写 Merge.yaml + 直接 patch clash-verge.yaml（proxies: / rules: 节），重载 Clash |
| `uninstall` | 删除所有注入项，还原 Merge.yaml，重载 Clash |
| `status` | 查询 Clash 运行时是否已加载规则，打印命中次数 |

install 同时写两处的原因见下文"Clash Verge 订阅刷新问题"。

生成的 Clash 代理配置：

```yaml
- name: mitmproxy-relay
  type: http          # HTTP CONNECT 代理
  server: 114.132.245.209
  port: 8444          # 安全组直接开放
  tls: true           # 外层 TLS，隐藏 CONNECT 目标，绕过 GFW
  skip-cert-verify: true
  sni: hxe.7hu.cn    # GFW 看到的 SNI
```

`skip-cert-verify: true`：tls_proxy.crt 由 mitmproxy CA 自签，Clash 跳过验证才能建立外层 TLS。

#### Clash TUN 模式（⚠️ 必须配置）

Clash Verge 开启 TUN 模式时，gvisor 在本地完成 TCP 握手但不转发数据，必须将服务器 IP 加入排除列表：

```yaml
tun:
  route-exclude-address:
    - 114.132.245.209/32
```

install 命令会自动处理此项。

#### ⚠️ Clash Verge 订阅刷新后需重新 install

`prepend-proxies` / `prepend-rules` 是 Clash Verge 应用层语法，mihomo 核心不识别。每次 Clash Verge 刷新订阅，会重新生成 `clash-verge.yaml`，将 Merge.yaml 中的 `prepend-*` 字段原样写入，而不合并进 `proxies:` / `rules:` 节——导致规则对 mihomo 不生效，流量恢复直连。

**症状**：`curl --proxy http://127.0.0.1:7897 -k -v https://api.anthropic.com 2>&1 | grep issuer` 输出 Google 的证书而非 mitmproxy。

**解决**：每次订阅刷新后，重新执行一次 install：
```bash
ssh -p 2222 sgyy@localhost 'bash -s install' < mitmproxy_capture.sh
```

#### 优化：改用 `clash_verge_script.js` 做运行时注入

为了解决 `mitmproxy_capture.sh` 在切换代理、刷新订阅或 Clash Verge 重写配置后容易被覆盖的问题，当前增加了 [`clash_verge_script.js`](../clash_verge_script.js) 作为更稳定的注入方案。

它和直接 patch `clash-verge.yaml` 的区别在于：

- `mitmproxy_capture.sh` 是修改生成后的静态配置文件，后续一旦被 Clash Verge 重建，注入内容就可能丢失
- `clash_verge_script.js` 是在 Clash Verge 载入最终配置时执行，对运行时 `config` 进行二次注入，不依赖某次生成出来的 YAML 文件长期保持不变

脚本会自动完成以下几件事：

- 注入 `mitmproxy-relay` 代理节点
- 将该节点加入常见的策略组，并放到首位
- 注入 `DOMAIN,api.anthropic.com,mitmproxy-relay` 规则
- 注入 `IP-CIDR,114.132.245.209/32,DIRECT,no-resolve`，避免请求 VPS 自身时发生回环
- 在开启 TUN 时补充 `route-exclude-address: 114.132.245.209/32`

这样即使用户切换代理、更新订阅，或者 Clash Verge 重新生成底层配置，只要该 Script 仍然挂载，目标流量就会继续被导向 `mitmproxy-relay`，不需要反复执行 `install`。

### 5. TLS 证书链

```
mitmproxy CA（~/.mitmproxy/mitmproxy-ca.pem，含私钥，勿外传）
    ├── tls_proxy.crt（hxe.7hu.cn）  ← tls_proxy.py 使用，外层 TLS
    └── 动态签发 api.anthropic.com 等证书  ← mitmproxy MITM 时使用
```

客户端需要信任 mitmproxy CA，才能接受 mitmproxy 伪造的内层证书（`api.anthropic.com`）。外层证书（`hxe.7hu.cn`）由 Clash 的 `skip-cert-verify: true` 跳过验证，无需安装。

### 6. `viewer/app.py`（Web 查看器，:8888）

Flask 应用，提供流量查看与分析界面。

**页面端点**：

| 路径 | 说明 |
|------|------|
| `/` | 流量列表主界面 |
| `/ca` | 下载 mitmproxy CA 证书（PEM 格式） |
| `/setup` | 含 macOS / Linux 一键安装命令的页面 |

**API 端点**：

| 路径 | 说明 |
|------|------|
| `GET /api/logs` | 分页查询日志，支持多维度过滤 |
| `GET /api/log/<id>` | 查询单条完整记录（含 body） |
| `GET /api/stats` | 聚合统计：域名 Top20、方法分布、状态码分布、时间线 |
| `GET /api/domains` | 所有出现过的域名列表 |
| `POST /api/clear` | 清空日志文件 |

`/api/logs` 过滤参数：`domain`、`method`、`status_min`/`status_max`、`search`（URL 关键字）、`body_search`（请求/响应体关键字）、`time_from`/`time_to`（Unix 时间戳）、`has_error`；分页参数：`page`、`per_page`（最大 500）。

日志文件有基于 mtime+size 的文件缓存，重复请求不重读磁盘。

---

## 开发机证书安装

mitmproxy 做 HTTPS MITM 时，客户端会收到由 mitmproxy CA 签发的伪造证书。Node.js（Claude Code）需信任该 CA 才能正常工作。

Web 查看器提供便捷安装页面：`http://114.132.245.209:8888/setup`

**macOS**（在开发机执行一次）：

```bash
curl -s http://114.132.245.209:8888/ca -o /tmp/mitmproxy-ca.pem && \
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/mitmproxy-ca.pem && \
echo 'export NODE_EXTRA_CA_CERTS=/tmp/mitmproxy-ca.pem' >> ~/.zshrc
```

**Linux**（在开发机执行一次）：

```bash
curl -s http://114.132.245.209:8888/ca | sudo tee /usr/local/share/ca-certificates/mitmproxy-ca.crt > /dev/null && \
sudo update-ca-certificates && \
echo 'export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mitmproxy-ca.crt' >> ~/.bashrc
```

> `NODE_EXTRA_CA_CERTS` 是 Node.js 专用环境变量，用于追加信任的 CA 证书。Node.js 默认不读取系统证书库，因此即使系统已安装，也需要单独设置此变量。安装后重启终端生效。

---

## 为其他开发机添加捕获

1. **安装 Clash 配置**（在服务器上执行）：
   ```bash
   ssh -p 2222 <user>@localhost 'bash -s install' < mitmproxy_capture.sh
   ```
2. **安装 CA 证书**：访问 `http://114.132.245.209:8888/setup`，按对应系统执行安装命令
3. **重启终端**，使 `NODE_EXTRA_CA_CERTS` 生效

> Clash TUN 模式下，流量由 TUN 透明拦截，**无需手动设置 `HTTPS_PROXY`**。若使用 curl 等工具手动测试，需指定 `--proxy http://127.0.0.1:7897`。

4. **验证**：
   ```bash
   curl --proxy http://127.0.0.1:7897 -k -v https://api.anthropic.com/v1/models 2>&1 | grep issuer
   # 期望: issuer: CN=mitmproxy; O=mitmproxy
   ```

---

## 端口全景

| 端口 | 位置 | 说明 |
|------|------|------|
| 8444 | 服务器（公网，安全组开放） | 对外入口，tls_proxy.py 监听，TLS 终止 |
| 8081 | 服务器（本地） | mitmproxy，流量捕获与记录 |
| 7890 | 服务器（本地） | Clash 出口代理（机场） |
| 8888 | 服务器（本地/可对外） | Web 查看器，含 /ca、/setup 端点 |
| 7897 | 开发机（本地） | Clash 混合代理端口（TUN 模式时流量自动路由） |

---

## Relay 模式（可选）

`start_relay.sh` 启动另一套 mitmproxy 实例，用于**拦截不转发**的场景（如接口 mock、测试录制）：

- **HTTP relay**：监听 8082（对外端口 80，若 < 1024 则 iptables 重定向至 8082）
- **HTTPS relay**：监听 8083（对外端口 443，若 < 1024 则 iptables 重定向至 8083）
- mitmproxy 以 `reverse` 模式运行，`MITM_RELAY_MODE=1` 让插件拦截请求、返回空响应并记录
- 开发机修改 hosts 将目标域名指向服务器 IP，流量进入 relay 后被记录并丢弃，不转发到真实目标

```bash
./start_relay.sh   # 前台运行，Ctrl+C 自动清理 iptables
```

关键参数说明：
- `--mode reverse:http://127.0.0.1:1`：reverse 模式（目标地址由 `keep_host_header` + Host 头决定，1 为占位符）
- `--set connection_strategy=lazy`：不主动建立上游连接
- `--set block_global=false`：允许接受所有来源连接
- `--set upstream_cert=false`（HTTPS relay）：不尝试验证上游证书

config.yaml 中 `relay_mode: false`（默认），正常捕获模式下不涉及此功能。
