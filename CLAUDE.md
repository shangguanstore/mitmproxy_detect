# 项目说明

## 开发机连接

Mac 开发机可通过 SSH 反向隧道访问：

```bash
ssh -p 2222 sgyy@localhost
```

## 项目结构

- `tls_proxy.py` — TLS 终止层，监听 :8444，转发到 mitmproxy :8081
- `traffic_logger.py` — mitmproxy 插件，记录流量到 logs/traffic.jsonl
- `mitmproxy_capture.sh` — 在 Mac 开发机上运行，配置 Clash 路由规则
- `start_proxy.sh` — 启动 tls_proxy + mitmproxy + web viewer
- `viewer/app.py` — Web 查看器，:8888

## 端口

| 端口 | 说明 |
|------|------|
| 8444 | tls_proxy（公网，安全组开放） |
| 8081 | mitmproxy（本地） |
| 7890 | Clash 出口代理（本地） |
| 8888 | Web 查看器 |

## 开发机需要的环境变量

```bash
export HTTPS_PROXY=http://127.0.0.1:7897
export NODE_EXTRA_CA_CERTS=/tmp/mitmproxy-ca.pem
```

## 协作规范

- **不要在未被要求的情况下执行 `git commit`**。写完代码后只报告结果，等用户明确说"commit"再提交。
