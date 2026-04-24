# 排查过程记录

记录从"开发机流量无法被捕获"到"完整方案跑通"的完整排查路径，以及每个坑的根因和解法。

---

## 问题起点

开发机访问 `hxe.7hu.cn`（服务器自有域名）时，流量出现在 mitmproxy 记录里；访问 `api.anthropic.com` 时，没有任何记录。

---

## 阶段一：SSH 反向隧道（能跑通，但被放弃）

**方案**：在开发机上建立反向隧道，把服务器的 mitmproxy 8081 映射到开发机本地：

```bash
ssh -R 18081:127.0.0.1:8081 server
```

然后开发机设置 `HTTPS_PROXY=http://127.0.0.1:18081`。

**效果**：能捕获，但方案本身有缺陷——

- 每台开发机都要手动建隧道，无法"简单配置就生效"
- 隧道断线后需要重建
- 只能用于当前终端会话，无法做到系统级透明代理

**放弃原因**：用户需要的是"其他开发机简单配置就能接入"，而不是每次都 SSH。

---

## 阶段二：HTTPS CONNECT over TLS 方案设计

**思路**：GFW 只嗅探 TLS ClientHello 里的 SNI，如果把 CONNECT 请求藏进 TLS 里，GFW 看到的只有外层 TLS 的 SNI（`hxe.7hu.cn`），里面的 `CONNECT api.anthropic.com:443` 是加密的，看不到。

**初步验证**：在服务器本地用 curl 测试：

```bash
curl --proxy https://127.0.0.1:8443 --proxy-insecure -k https://api.anthropic.com/v1/models
# → 401，mitmproxy 成功捕获
```

本地完全跑通，说明方案可行，问题出在"开发机到服务器"这一跳。

---

## 阶段三：Clash TUN DIRECT 不实际转发

**现象**：在开发机上 `nc -v 114.132.245.209 8443` 显示 `Connection succeeded`，但服务器上 tls_proxy 的日志完全没有任何连接记录。

**根因**：Clash 开启 TUN（gvisor 栈）后，所有 TCP 连接都由 gvisor 虚拟网络栈接管。当某个连接命中 `DIRECT` 规则时，gvisor **在本地完成了三次握手**（所以 nc 看到了 Connected），但 gvisor 随后并没有把这个连接转发到真实的目标 IP——数据包根本没有离开开发机。

**验证方式**：在服务器上同时抓包（`tcpdump -i any port 8443`），确认服务器侧 zero packets。

**解法**：在 Clash TUN 配置里加 `route-exclude-address`，让目标服务器 IP 完全绕过 TUN，走系统真实路由：

```yaml
tun:
  route-exclude-address:
    - 114.132.245.209/32
```

---

## 阶段四：端口 8443 被云安全组封锁

**现象**：加了 `route-exclude-address` 后，nc 连接从"立即 Connected"变成"Operation timed out"——连接不再被 TUN 伪造，走的是真实网络，但超时了。

**根因**：腾讯云服务器的安全组（等价于防火墙入站规则）没有开放 8443 端口，外部流量无法到达。

**验证**：测试 443 和 80 端口均可达，8443 不可达。

**解法**：改用已开放的 443 端口。tls_proxy 无法以非 root 身份直接绑定 443，改用 iptables PREROUTING 做端口转发：

```bash
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-ports 8444
```

tls_proxy 监听本地 8444，iptables 把外部 443 的流量重定向过来。同步更新开发机 Clash 配置，把 mitmproxy-relay 的 port 从 8443 改为 443。

---

## 阶段五：tls_proxy 遭遇端口扫描崩溃

**现象**：首次部署后测试成功，但过了一段时间再测，流量不走 mitmproxy，证书变回 Cloudflare 的真实证书。

**根因**：tls_proxy.py 的异常捕获只有 `ssl.SSLError`：

```python
try:
    tls_conn = ctx.wrap_socket(conn, server_side=True)
except ssl.SSLError:          # ← 只捕获这个
    conn.close()
    continue
```

公网 443 端口会持续收到各类端口扫描器的连接（发送非 TLS 数据或立即断开），这些连接触发的是 `ConnectionResetError`（`OSError` 的子类），没有被捕获，异常直接传播到主循环外，**整个进程退出**。

tls_proxy 死掉后，iptables 仍在把 443 转发到 8444，但 8444 没有监听者，连接被拒绝，Clash 的 mitmproxy-relay 失败，回落到机场直连。

**修复**：

```python
except (ssl.SSLError, OSError):   # 捕获所有连接级别错误
    conn.close()
    continue
```

---

## 阶段六：prepend-proxies / prepend-rules 被 mihomo 忽略

**现象**：卸载重装后，`status` 显示规则已激活，但实际 curl 返回的是 Cloudflare 真实证书，流量没走 mitmproxy。

**根因**：Clash Verge 在配置文件里写的是 `prepend-proxies:` 和 `prepend-rules:` 这两个顶级键，这是 **Clash Verge 应用层**的处理指令，mihomo 核心（`PUT /configs?force=true`）加载同一个文件时，直接忽略这两个不认识的键。

结果：

- `proxies:` 节里没有 `mitmproxy-relay`（它在 `prepend-proxies:` 里）
- `rules:` 节里没有 DOMAIN 规则（它在 `prepend-rules:` 里）
- mihomo 找不到 proxy，规则验证失败，整个配置加载时报 "proxy not found" 错误

**调试手段**：通过 mihomo API 查看运行时实际生效的规则：

```bash
curl -s --unix-socket /tmp/verge/verge-mihomo.sock "http://localhost/rules" \
  | python3 -c "import sys,json; [print(r) for r in json.load(sys.stdin)['rules'][:5]]"
```

第一条规则是 `IP-CIDR 1.1.1.1/32`，说明我们的 DOMAIN 规则根本不在里面。

**解法**：`mitmproxy_capture.sh` 脚本同时操作两处：

1. **Merge.yaml**（持久化）：写 `prepend-proxies` / `prepend-rules`，供 Clash Verge 下次重新生成配置时合并
2. **clash-verge.yaml**（立即生效）：直接把 proxy 插入 `proxies:` 节第一条，把 rule 插入 `rules:` 节第一条，再通过 mihomo API reload

---

## 最终验证

```bash
# 开发机上
~/mitmproxy_capture.sh install

curl --proxy http://127.0.0.1:7897 -k -v https://api.anthropic.com/v1/models 2>&1 | grep issuer
# 输出: issuer: CN=mitmproxy; O=mitmproxy  ← 确认走了 mitmproxy
```

服务器 mitmproxy 日志：

```
<dev_machine_ip>: GET https://api.anthropic.com/v1/models HTTP/2.0
     << HTTP/2.0 401 Unauthorized 141b
```

---

## 踩坑汇总

| # | 现象 | 根因 | 解法 |
|---|------|------|------|
| 1 | nc 显示 Connected，但服务器收不到包 | Clash TUN gvisor DIRECT 在本地假握手 | 加 `route-exclude-address` 绕过 TUN |
| 2 | 连接 8443 超时 | 云安全组未开放 8443 | 改用已开放的 443，加 iptables REDIRECT |
| 3 | tls_proxy 过一段时间自动挂掉 | 端口扫描触发 `ConnectionResetError`，进程崩溃 | 异常捕获改为 `(ssl.SSLError, OSError)` |
| 4 | status 显示规则激活，但实际走机场 | `prepend-proxies/rules` 是 Clash Verge 应用层语法，mihomo 不认识 | 直接写入 `proxies:` 和 `rules:` 节 |
