# Relay 模式部署指南

将特定域名的流量通过 hosts 文件指向本服务器，由 mitmproxy 在服务器端接住并解析（不做转发）。

---

## 架构说明

```
开发机
  └─ /etc/hosts: example.com → 服务器IP
  └─ 信任 mitmproxy CA 证书

             HTTP :80  ──→  mitmdump (reverse:http)  ──→ 记录日志，返回空 200
服务器       HTTPS :443 ──→  mitmdump (reverse:https) ──→ TLS 终结 → 记录日志，返回空 200
             :8888       ──→  Web 查看器
```

---

## 第一步：服务器配置

### 1.1 配置目标域名

编辑 `config.yaml`，在 `target_sites` 下填写要捕获的域名（子串匹配）：

```yaml
target_sites:
  - example.com        # 匹配 www.example.com、api.example.com 等
  - api.myservice.com
```

留空则捕获所有打到服务器的流量。

### 1.2 确认端口配置

`config.yaml` 中的 relay 端口默认为：

```yaml
relay_http_port: 80
relay_https_port: 443
```

如需修改，同步更新开发机 hosts 指向的端口（通常保持 80/443 即可）。

### 1.3 解决低端口权限问题

端口 80/443 需要 root 或特殊权限，二选一：

**方案 A：用 sudo 启动**
```bash
sudo ./start_relay.sh
```

**方案 B：给 mitmdump 授权（推荐，只需执行一次）**
```bash
sudo setcap 'cap_net_bind_service=+ep' $(which mitmdump)
# 之后普通用户即可监听低端口
./start_relay.sh
```

### 1.4 生成 mitmproxy CA 证书

如果是首次使用 mitmproxy，需要先跑一次让它生成 CA 证书：

```bash
mitmdump --version  # 确认已安装
# 首次启动会自动生成 ~/.mitmproxy/ 目录和证书
mitmdump -s traffic_logger.py --listen-port 8081 &
sleep 2 && kill %1
```

CA 证书位于：`~/.mitmproxy/mitmproxy-ca-cert.pem`

### 1.5 启动 relay

```bash
cd ~/test_mitmproxy
./start_relay.sh
```

成功后会看到：
```
[Relay] HTTP  端口: 80
[Relay] HTTPS 端口: 443
[Relay] 启动 HTTP relay...
[Relay] 启动 HTTPS relay...
[PID] HTTP=xxxxx  HTTPS=xxxxx
[Viewer] 启动 Web 查看器...
Web 查看器启动中：http://0.0.0.0:8888
```

---

## 第二步：开发机配置

### 2.1 修改 hosts 文件

将目标域名指向服务器 IP：

**macOS / Linux**（需要 sudo）
```bash
sudo nano /etc/hosts
```

**Windows**（管理员权限）
```
C:\Windows\System32\drivers\etc\hosts
```

添加如下内容（替换为实际 IP 和域名）：
```
1.2.3.4  example.com
1.2.3.4  api.example.com
1.2.3.4  www.example.com
```

修改后验证是否生效：
```bash
ping example.com       # 应解析到 1.2.3.4
curl http://example.com  # 应有响应（空 200）
```

### 2.2 安装 mitmproxy CA 证书（HTTPS 必须）

**从服务器拷贝证书到开发机：**
```bash
scp user@服务器IP:~/.mitmproxy/mitmproxy-ca-cert.pem ~/Downloads/
```

> 只需要 `mitmproxy-ca-cert.pem`，不要拷贝 `mitmproxy-ca.pem`（私钥）。

**macOS（终端执行）：**
```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ~/Downloads/mitmproxy-ca-cert.pem
```

**Windows（管理员 PowerShell）：**
```powershell
certutil -addstore -f "ROOT" $env:USERPROFILE\Downloads\mitmproxy-ca-cert.pem
```

**Linux（Ubuntu / Debian）：**
```bash
sudo cp ~/Downloads/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates
```

**Firefox 需单独导入：**
`about:preferences#privacy` → 证书 → 查看证书 → 证书颁发机构 → 导入 → 勾选"信任此 CA 标识网站"

详细步骤见 [install-ca-cert.md](./install-ca-cert.md)。

### 2.3 验证 HTTPS 是否正常

```bash
curl https://example.com -v
# 应返回 HTTP 200，且不报证书错误
```

---

## 第三步：查看流量

浏览器打开：`http://服务器IP:8888`

流量记录存储在：`logs/traffic.jsonl`

---

## 停止服务

在运行 `start_relay.sh` 的终端按 `Ctrl+C`，脚本会自动清理两个 mitmdump 进程。

---

## 常见问题

### curl 报 "Connection refused"

服务器的 80/443 端口没有在监听，检查 relay 是否正常启动：
```bash
ss -tlnp | grep -E ':80|:443'
```

### curl 报证书错误（SSL certificate problem）

开发机没有安装 mitmproxy CA 证书，按第二步 2.2 操作。
如需跳过验证临时测试：`curl -k https://example.com`

### hosts 修改后 ping 域名还是旧 IP

DNS 缓存问题：
```bash
# macOS
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder

# Linux
sudo systemd-resolve --flush-caches

# Windows（管理员）
ipconfig /flushdns
```

### 端口被占用

```bash
# 查看占用 80 端口的进程
sudo lsof -i :80
sudo lsof -i :443
```

---

## 恢复开发机

不需要抓包时，恢复 hosts 文件，删除证书：

```bash
# 删除 hosts 条目（编辑文件去掉相关行）
sudo nano /etc/hosts

# macOS 删除证书
sudo security find-certificate -c "mitmproxy" -Z /Library/Keychains/System.keychain
sudo security delete-certificate -Z <上面输出的HASH> /Library/Keychains/System.keychain

# Windows 删除证书（管理员 PowerShell）
certutil -delstore "ROOT" "mitmproxy"
```
