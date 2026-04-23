# 开发机安装 mitmproxy CA 证书

在通过 hosts 文件将域名指向抓包服务器后，HTTPS 流量需要由 mitmproxy 进行 TLS 解密。
为了让开发机不报证书错误，需要将 mitmproxy 自动生成的 CA 证书安装为受信任的根证书颁发机构。

---

## 第一步：从服务器获取证书文件

mitmproxy 首次启动后会在服务器的 `~/.mitmproxy/` 目录生成 CA 证书。

```bash
# 在开发机上执行，将证书拷贝到本地
scp user@server-ip:~/.mitmproxy/mitmproxy-ca-cert.pem ~/Downloads/mitmproxy-ca-cert.pem
```

> 只需要 `mitmproxy-ca-cert.pem`，不要拷贝 `mitmproxy-ca.pem`（那是私钥）。

---

## 第二步：安装证书（按开发机系统选择）

### macOS

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ~/Downloads/mitmproxy-ca-cert.pem
```

安装后，Chrome、Safari、curl、Python requests 等所有读取系统证书链的程序均自动信任，无需重启。

如需验证是否安装成功：

```bash
security find-certificate -c "mitmproxy" /Library/Keychains/System.keychain
```

---

### Windows

**方法一：双击安装（图形界面）**

1. 将 `mitmproxy-ca-cert.pem` 重命名为 `mitmproxy-ca-cert.crt`（Windows 依赖扩展名识别格式）
2. 双击文件 → 点击「安装证书」
3. 选择「本地计算机」→ 下一步
4. 选择「将所有证书都放入下列存储」→ 浏览 → 选择「受信任的根证书颁发机构」
5. 下一步 → 完成

**方法二：命令行（管理员 PowerShell）**

```powershell
certutil -addstore -f "ROOT" $env:USERPROFILE\Downloads\mitmproxy-ca-cert.pem
```

安装后，Chrome、Edge、IE、curl（系统版）等程序自动信任。

---

### Linux（Ubuntu / Debian）

```bash
sudo cp ~/Downloads/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates
```

安装后，curl、wget、Python requests 等程序自动信任。

---

## Firefox 单独处理（所有系统通用）

Firefox 维护自己的证书仓库，不读取系统证书，需单独导入：

1. 地址栏输入 `about:preferences#privacy`
2. 滚动到底部「证书」区域 → 点击「查看证书」
3. 切换到「证书颁发机构」选项卡 → 点击「导入」
4. 选择 `mitmproxy-ca-cert.pem` 文件
5. 勾选「信任此 CA 标识网站」→ 确定

---

## 卸载证书（不再需要时）

### macOS

```bash
# 先找到证书的 SHA-1 哈希
security find-certificate -c "mitmproxy" -Z /Library/Keychains/System.keychain

# 用哈希删除（替换 <HASH> 为上面输出的值）
sudo security delete-certificate -Z <HASH> /Library/Keychains/System.keychain
```

### Windows（管理员 PowerShell）

```powershell
certutil -delstore "ROOT" "mitmproxy"
```

### Linux

```bash
sudo rm /usr/local/share/ca-certificates/mitmproxy.crt
sudo update-ca-certificates --fresh
```

---

## 安全说明

- 该 CA 证书只安装在你自己的开发机上，不影响其他人
- 拥有对应私钥（`mitmproxy-ca.pem`）的人才能签发受信任证书，私钥保存在服务器上，不要外传
- 不再需要抓包时，按照上方「卸载证书」步骤移除即可
