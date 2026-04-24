# 实现原理：跨 GFW 流量捕获

## 背景与目标

目标：开发机（国内，macOS + Clash）访问 `api.anthropic.com` 的流量，全部被服务端 mitmproxy 捕获并记录，不使用 SSH 隧道，配置简单可复用。

核心难点：GFW 通过 **SNI 嗅探**封锁 `api.anthropic.com`——TLS ClientHello 里的 SNI 字段是明文，GFW 看到就 RST。直接在国内访问该域名不可能绕过。

---

## 方案：HTTPS CONNECT over TLS

将 HTTP CONNECT 请求藏进 TLS 隧道里，让 GFW 只看到外层 TLS 的 SNI（`hxe.7hu.cn`，不被封锁），看不到里面 CONNECT 的目标（`api.anthropic.com`）。

```
开发机 curl/SDK
    ↓ HTTP CONNECT api.anthropic.com:443
Clash（本地 7897）
    ↓ 建立 TLS 连接到 114.132.245.209:443，SNI=hxe.7hu.cn
    ↓ 在 TLS 内发送 CONNECT api.anthropic.com:443
[GFW 只看到 SNI=hxe.7hu.cn，放行]
    ↓
服务器 iptables: 443 → 8444
    ↓
tls_proxy.py（8444）终止 TLS，转发原始 TCP
    ↓
mitmproxy（8081，upstream 模式）
    ↓ 拦截 TLS，生成 api.anthropic.com 的伪造证书
    ↓ 记录请求/响应到 traffic.jsonl
    ↓
服务器 Clash（7890）→ api.anthropic.com（真实请求）
```

---

## 各组件说明

### 1. `tls_proxy.py`（服务端）

监听本地 8444 端口，完成两件事：

- **终止外层 TLS**：用 `hxe.7hu.cn` 的证书（由 mitmproxy CA 签发），接受客户端的 TLS 握手
- **透明转发**：TLS 解密后，将原始 TCP 字节流双向 relay 给 mitmproxy:8081

```
客户端 TLS ──→ tls_proxy:8444 ──→ 明文 TCP ──→ mitmproxy:8081
```

之所以需要这层：mitmproxy 本身不支持"接受 HTTPS 入站再转发 HTTP CONNECT"的组合模式，tls_proxy 做 TLS 终止后，mitmproxy 只看到普通的 HTTP CONNECT。

### 2. iptables PREROUTING（服务端）

```bash
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 8444
```

端口 443 是云服务器安全组默认开放的。tls_proxy 以非 root 用户运行，无法直接绑定 443，通过 iptables REDIRECT 把外部 443 流量转到 8444。

### 3. Clash 代理配置（开发机）

```yaml
proxies:
  - name: mitmproxy-relay
    type: http          # HTTP CONNECT 代理
    server: 114.132.245.209
    port: 443
    tls: true           # 外层 TLS
    skip-cert-verify: true
    sni: hxe.7hu.cn    # GFW 看到的 SNI

rules:
  - DOMAIN,api.anthropic.com,mitmproxy-relay  # 必须是第一条

tun:
  route-exclude-address:
    - 114.132.245.209/32  # 绕过 TUN，见下文
```

**`route-exclude-address` 的作用**：Clash 开启 TUN（gvisor 栈）后，所有出站 TCP 都被虚拟网卡接管。若服务器 IP 走 DIRECT 规则，gvisor 在本地完成 TCP 握手（nc 显示"Connected"），但实际不转发数据——数据包永远到不了服务器。将服务器 IP 加入 `route-exclude-address` 后，这个 IP 的流量绕过 TUN，直接走系统路由，真正到达服务器。

### 4. Merge.yaml（开发机）

```
~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/Merge.yaml
```

Clash Verge 每次更新订阅时会重新生成主配置，Merge.yaml 里的 `prepend-proxies` / `prepend-rules` 会被合并进去，保证配置在订阅更新后不丢失。

> **注意**：Merge.yaml 的处理由 Clash Verge 应用层完成，mihomo 核心本身不认识 `prepend-proxies` / `prepend-rules` 这两个键。直接通过 API reload 配置时，必须确保 proxy 在 `proxies:` 节、rule 在 `rules:` 节，脚本 `mitmproxy_capture.sh` 会同时写两处。

### 5. mitmproxy（服务端，upstream 模式）

```bash
mitmdump -s traffic_logger.py \
  --listen-port 8081 \
  --mode upstream:http://127.0.0.1:7890 \
  --set ssl_insecure=true
```

- **upstream 模式**：收到 CONNECT 后，把请求转发给服务器本地的 Clash（7890），由 Clash 出国访问真实目标
- **TLS 拦截**：mitmproxy 对客户端伪造目标域名的证书（由 mitmproxy CA 签发），从而解密 HTTPS 内容
- **ssl_insecure**：允许上游连接时跳过证书验证

### 6. TLS 证书链

```
mitmproxy CA（~/.mitmproxy/mitmproxy-ca.pem）
    └── 签发 hxe.7hu.cn 证书（tls_proxy.crt）  ← tls_proxy 使用
    └── 动态签发 api.anthropic.com 证书          ← mitmproxy 拦截时使用
```

开发机上 Clash 设置了 `skip-cert-verify: true`，所以 hxe.7hu.cn 证书不需要被系统信任。若需要应用程序透明信任（如直接跑 Python SDK 不加 `-k`），需要把 mitmproxy CA 安装到系统钥匙串。

---

## 为其他开发机添加捕获

1. 将 `mitmproxy_capture.sh` 复制到目标开发机
2. 执行 `./mitmproxy_capture.sh install`
3. 测试：`curl --proxy http://127.0.0.1:7897 -k -v https://api.anthropic.com/v1/models 2>&1 | grep issuer`
   - 期望输出：`issuer: CN=mitmproxy; O=mitmproxy`

脚本幂等，重复执行不会重复添加配置。订阅更新后若失效，重新运行 `install` 即可。

---

## 端口全景

| 端口 | 位置 | 说明 |
|------|------|------|
| 443  | 服务器（公网） | 对外入口，iptables 重定向到 8444 |
| 8444 | 服务器（本地） | tls_proxy.py 监听，TLS 终止 |
| 8081 | 服务器（本地） | mitmproxy，流量捕获 |
| 7890 | 服务器（本地） | Clash 出口代理（机场） |
| 8888 | 服务器（本地） | Web 查看器 |
| 7897 | 开发机（本地） | Clash 混合代理端口 |
