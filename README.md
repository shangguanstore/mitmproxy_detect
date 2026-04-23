# mitmproxy 流量捕获 + Web 可视化系统

捕获发送到特定站点的 HTTP/HTTPS 流量，并通过 Web 界面进行查看、筛选和分析。

## 目录结构

```
test_mitmproxy/
├── config.yaml           # 配置文件（目标站点、端口等）
├── traffic_logger.py     # mitmproxy 捕获插件
├── logs/
│   └── traffic.jsonl     # JSONL 格式日志（自动创建）
├── viewer/
│   ├── app.py            # Flask Web 查看器后端
│   └── templates/
│       └── index.html    # Web 前端
├── start_proxy.sh        # 单独启动代理
├── start_viewer.sh       # 单独启动查看器
└── start_all.sh          # 同时启动两者
```

## 端口说明

| 服务 | 端口 | 说明 |
|------|------|------|
| mitmproxy 代理 | 8081 | 设置客户端代理到此端口 |
| Web 查看器 | 8888 | 浏览器访问此端口查看日志 |
| Clash 上游代理 | 7890 | mitmproxy 捕获后转发到此处出口 |

> 端口 8080 已被 nginx 占用，故使用 8081。

流量完整链路：
```
客户端（proxy=8081）→ mitmproxy:8081（拦截记录）→ Clash:7890（出口路由）→ 目标服务器
```

## 快速开始

### 1. 配置目标站点

编辑 `config.yaml`，填入要监控的域名：

```yaml
target_sites:
  - example.com
  - api.myservice.com
```

留空则捕获**所有**流经代理的流量。

### 2. 配置上游代理（Clash）

服务器上运行了 Clash（混合代理端口 7890），`config.yaml` 中已配置 mitmproxy 将流量转发给 Clash：

```yaml
upstream_proxy: http://127.0.0.1:7890
```

启动脚本会自动读取此配置，以 `--mode upstream` 启动 mitmproxy。**无需手动修改启动脚本**。

如需临时切换为直连（不经过 Clash），将该行注释掉后重启代理：

```yaml
# upstream_proxy: http://127.0.0.1:7890
```

### 3. 安装 CA 证书（HTTPS 解密必须）

CA 证书已生成在 `~/.mitmproxy/mitmproxy-ca-cert.pem`。

```bash
# Ubuntu/Debian 系统信任库（已执行）
sudo cp ~/.mitmproxy/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates
```

浏览器需单独导入：
- **Chrome**：设置 → 隐私和安全 → 安全 → 管理证书 → 导入 `~/.mitmproxy/mitmproxy-ca-cert.pem`
- **Firefox**：设置 → 隐私与安全 → 证书 → 查看证书 → 颁发机构 → 导入

### 4. 启动服务

```bash
cd ~/test_mitmproxy

# 方式一：同时启动代理和查看器
./start_all.sh

# 方式二：分别启动（推荐，方便各自重启）
./start_proxy.sh    # 终端1
./start_viewer.sh   # 终端2
```

### 5. 设置客户端代理

让目标客户端的流量经过代理：

```bash
# 当前终端的所有命令（临时）
export http_proxy=http://127.0.0.1:8081
export https_proxy=http://127.0.0.1:8081

# 验证：使用 curl 发送请求
curl -s https://httpbin.org/get
```

### 6. 访问 Web 界面

在浏览器打开：`http://<服务器IP>:8888`

## Web 界面功能

| 功能 | 说明 |
|------|------|
| 统计卡片 | 总请求数、唯一域名数、平均响应时间、错误率 |
| 方法/状态码分布图 | 直观查看 GET/POST 比例、2xx/4xx/5xx 分布 |
| 请求时间线 | 按分钟统计的请求量柱状图 |
| 过滤面板 | 按域名、方法、状态码范围、URL 关键词、Body 关键词筛选 |
| 请求列表 | 分页表格，点击行查看完整请求/响应详情 |
| 详情弹窗 | 请求头、请求体、响应头、响应体（JSON 自动格式化） |
| 自动刷新 | 每 5 秒自动刷新，实时查看新流量 |
| 清空日志 | 一键清除日志文件 |
| 连接失败记录 | 上游连接失败（如 DNS 解析到错误 IP）时仍记录完整请求头/体，状态列显示 **ERR**，详情响应 Tab 显示错误原因 |

## 日志格式（JSONL）

每行一条记录，字段说明：

```json
{
  "id": "1713800000.123456",
  "timestamp": 1713800000.123456,
  "datetime": "2026-04-22 17:00:00",
  "host": "api.example.com",
  "path": "/v1/users",
  "url": "https://api.example.com/v1/users",
  "method": "POST",
  "request_headers": {"content-type": "application/json", ...},
  "request_body": "{\"key\": \"value\"}",
  "status_code": 200,         // 连接失败时为 null
  "error": null,               // 连接失败时为错误原因字符串，成功时为 null
  "response_headers": {"content-type": "application/json", ...},
  "response_body": "{\"id\": 1}",
  "content_type": "application/json; charset=utf-8",
  "duration_ms": 123.45,
  "request_size": 256,
  "response_size": 1024
}
```

## 命令行日志分析

```bash
# 查看最新 20 条
tail -20 logs/traffic.jsonl | python3 -m json.tool

# 统计各域名请求数
cat logs/traffic.jsonl | python3 -c "
import json,sys
from collections import Counter
c=Counter(json.loads(l)['host'] for l in sys.stdin if l.strip())
[print(f'{v:5d}  {k}') for k,v in c.most_common(20)]
"

# 找出所有 4xx/5xx 错误
grep -E '"status_code": [45]' logs/traffic.jsonl | python3 -m json.tool

# 找出所有连接失败（DNS/TLS/超时等）
grep '"error":' logs/traffic.jsonl | grep -v '"error": null' | python3 -m json.tool

# 按耗时排序（最慢的 10 个）
cat logs/traffic.jsonl | python3 -c "
import json,sys
entries=[json.loads(l) for l in sys.stdin if l.strip()]
for e in sorted(entries,key=lambda x:x.get('duration_ms',0) or 0,reverse=True)[:10]:
    print(f'{e.get(\"duration_ms\",0):8.1f}ms  {e[\"method\"]:6s}  {e[\"url\"]}')
"
```

## 修改配置

编辑 `config.yaml` 后**重启代理**生效（查看器无需重启）：

```yaml
target_sites:
  - example.com        # 只记录这个域名的流量

max_body_size: 204800  # body 最大记录 200KB

proxy_port: 8081       # 代理端口
viewer_port: 8888      # 查看器端口

upstream_proxy: http://127.0.0.1:7890  # 上游 Clash 代理，注释掉则直连
```

## 故障排查

### 端口已被占用（Address already in use）

重复运行 `start_all.sh` 或上次未正常退出时，旧进程仍在占用 8081 / 8888 端口。

**定位占用进程：**

```bash
ss -tlnp | grep -E '8081|8888'
# 输出示例：
# LISTEN 0 100 0.0.0.0:8081  users:(("mitmdump",pid=2083195,...))
# LISTEN 0 128 0.0.0.0:8888  users:(("python3",pid=2083196,...))
```

**一行命令清理：**

```bash
ss -tlnp | grep -E '8081|8888' | grep -oP 'pid=\K[0-9]+' | xargs -r kill
```

之后再执行 `./start_all.sh` 即可。

> `ps -ax | grep start` 找不到是因为进程名是 `mitmdump` / `python3`，不含 "start" 关键字，用 `ss -tlnp` 按端口查更准确。
