#!/usr/bin/env bash
# mitmproxy 流量捕获配置 — 安装 / 卸载
# 用法: ./mitmproxy_capture.sh install | uninstall | status

set -euo pipefail

CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
CLASH_CFG="$CLASH_DIR/clash-verge.yaml"
MERGE_YAML="$CLASH_DIR/profiles/Merge.yaml"
MIHOMO_SOCK="/tmp/verge/verge-mihomo.sock"

SERVER_IP="114.132.245.209"
SERVER_PORT="8444"
SERVER_SNI="hxe.7hu.cn"
PROXY_NAME="mitmproxy-relay"
TARGET_DOMAIN="api.anthropic.com"

check_env() {
    [ -f "$CLASH_CFG" ] || { echo "错误: 找不到 $CLASH_CFG"; exit 1; }
    [ -S "$MIHOMO_SOCK" ] || { echo "错误: Clash Verge 未运行"; exit 1; }
}

reload_clash() {
    local r
    r=$(curl -s --unix-socket "$MIHOMO_SOCK" \
        -X PUT "http://localhost/configs?force=true" \
        -H "Content-Type: application/json" \
        -d "{\"path\":\"$CLASH_CFG\"}" 2>&1)
    if echo "$r" | grep -q '"message"'; then
        echo "⚠ 重载失败: $r"; return 1
    fi
    echo "✓ Clash 配置已重载"
}

# ── 安装：写 Merge.yaml + 直接 patch clash-verge.yaml ──
install() {
    check_env
    echo "=== 安装 mitmproxy 捕获配置 ==="

    # Merge.yaml（供 Clash Verge 订阅更新时合并）
    cat > "$MERGE_YAML" << EOF
prepend-proxies:
  - name: ${PROXY_NAME}
    type: http
    server: ${SERVER_IP}
    port: ${SERVER_PORT}
    tls: true
    skip-cert-verify: true
    sni: ${SERVER_SNI}

prepend-rules:
  - DOMAIN,${TARGET_DOMAIN},${PROXY_NAME}
EOF
    echo "✓ Merge.yaml 已写入"

    # 直接 patch clash-verge.yaml
    python3 - "$CLASH_CFG" "$SERVER_IP" "$SERVER_PORT" \
              "$SERVER_SNI" "$PROXY_NAME" "$TARGET_DOMAIN" << 'PYEOF'
import sys, re

cfg_path, server_ip, server_port, server_sni, proxy_name, target_domain = sys.argv[1:]
lines = open(cfg_path).readlines()

proxy_block = (
    f"- name: {proxy_name}\n"
    f"  type: http\n"
    f"  server: {server_ip}\n"
    f"  port: {server_port}\n"
    f"  tls: true\n"
    f"  skip-cert-verify: true\n"
    f"  sni: {server_sni}\n"
)
rule_line    = f"- DOMAIN,{target_domain},{proxy_name}\n"
exclude_line = f"  - {server_ip}/32\n"

# 1. proxies: 节插入第一条（替换同名旧块，确保端口更新）
pi = next((i for i,l in enumerate(lines) if l.rstrip('\n') == 'proxies:'), None)
if pi is None: print("错误: 找不到 proxies:"); sys.exit(1)
if pi+1 < len(lines) and lines[pi+1].startswith(f"- name: {proxy_name}"):
    end = pi + 2
    while end < len(lines) and lines[end].startswith("  "):
        end += 1
    del lines[pi+1:end]
    print(f"✓ 已替换旧 {proxy_name} 块（更新端口）")
else:
    print(f"✓ {proxy_name} 已插入 proxies:")
lines.insert(pi+1, proxy_block)

# 2. rules: 节插入第一条
content = ''.join(lines)
lines = content.splitlines(keepends=True)
ri = next((i for i,l in enumerate(lines) if l.rstrip('\n') == 'rules:'), None)
if ri is None: print("错误: 找不到 rules:"); sys.exit(1)
if lines[ri+1] != rule_line:
    lines.insert(ri+1, rule_line)
    print(f"✓ DOMAIN 规则已插入 rules: 首位")
else:
    print(f"  rules: 已有规则，跳过")

# 3. tun route-exclude-address
content = ''.join(lines)
if 'route-exclude-address:' not in content:
    content = re.sub(r'(  stack: \S+\n)',
                     r'\1  route-exclude-address:\n' + f'  - {server_ip}/32\n',
                     content, count=1)
    print(f"✓ 新增 route-exclude-address: {server_ip}/32")
elif exclude_line not in content:
    content = content.replace('route-exclude-address:\n',
                              f'route-exclude-address:\n{exclude_line}', 1)
    print(f"✓ 已添加 {server_ip}/32 到 route-exclude-address")
else:
    print(f"  route-exclude-address 已有 {server_ip}/32，跳过")

open(cfg_path, 'w').write(content)
PYEOF

    reload_clash
    echo ""
    echo "=== 安装完成 ==="
    echo "测试: curl --proxy http://127.0.0.1:7897 -k -v https://api.anthropic.com/v1/models 2>&1 | grep issuer"
    echo "期望: issuer: CN=mitmproxy; O=mitmproxy"
}

# ── 卸载：清理所有注入点 ─────────────────────────────────
uninstall() {
    check_env
    echo "=== 卸载 mitmproxy 捕获配置 ==="

    # 还原 Merge.yaml
    cat > "$MERGE_YAML" << 'EOF'
# Profile Enhancement Merge Template for Clash Verge

profile:
  store-selected: true
EOF
    echo "✓ Merge.yaml 已还原"

    # patch clash-verge.yaml
    python3 - "$CLASH_CFG" "$SERVER_IP" "$PROXY_NAME" "$TARGET_DOMAIN" << 'PYEOF'
import sys, re

cfg_path, server_ip, proxy_name, target_domain = sys.argv[1:]
content = open(cfg_path).read()

# 删除 proxies: 里的 mitmproxy-relay 块
content, n = re.subn(
    rf'^- name: {re.escape(proxy_name)}\n(?:  [^\n]*\n)*',
    '', content, count=1, flags=re.MULTILINE)
print("✓ 已从 proxies: 移除" if n else "  proxies: 中未找到，跳过")

# 删除所有包含 proxy_name 的 DOMAIN 规则行（rules: 和 prepend-rules: 里都清）
content, n = re.subn(
    rf'^- DOMAIN,{re.escape(target_domain)},{re.escape(proxy_name)}\n',
    '', content, flags=re.MULTILINE)
print(f"✓ 已删除 {n} 条 DOMAIN 规则" if n else "  未找到 DOMAIN 规则，跳过")

# 删除 prepend-proxies: 里的 mitmproxy-relay 块（兼容旧格式）
content, n = re.subn(
    rf'^  - name: {re.escape(proxy_name)}\n(?:    [^\n]*\n)*',
    '', content, count=1, flags=re.MULTILINE)
if n: print("✓ 已从 prepend-proxies: 移除")

# 删除 route-exclude-address 里的服务器 IP
content, n = re.subn(rf'  - {re.escape(server_ip)}/32\n', '', content)
print(f"✓ 已从 route-exclude-address 移除 {server_ip}/32" if n else "  未找到 route-exclude-address 条目，跳过")

open(cfg_path, 'w').write(content)
PYEOF

    reload_clash
    echo "=== 卸载完成 ==="
}

# ── 状态 ─────────────────────────────────────────────────
status() {
    echo "=== 运行状态 ==="
    python3 - "$MIHOMO_SOCK" "$PROXY_NAME" "$TARGET_DOMAIN" << 'PYEOF'
import sys, json, urllib.request

sock, proxy_name, target_domain = sys.argv[1:]

# 用 curl 走 unix socket 拿数据
import subprocess

def get(path):
    r = subprocess.run(
        ['curl', '-s', '--unix-socket', sock, f'http://localhost{path}'],
        capture_output=True, text=True)
    return json.loads(r.stdout)

rules    = get('/rules').get('rules', [])
proxies  = get('/proxies').get('proxies', {})

rule = next((r for r in rules if target_domain in r.get('payload','') and proxy_name in r.get('proxy','')), None)
proxy_ok = proxy_name in proxies

if rule and proxy_ok:
    hits = rule['extra']['hitCount']
    print(f"✓ 规则已激活，命中 {hits} 次")
    print(f"  规则: {rule['type']} {rule['payload']} -> {rule['proxy']}")
    p = proxies[proxy_name]
    print(f"  代理: {p.get('server')}:{p.get('port')} type={p.get('type')}")
elif rule and not proxy_ok:
    print(f"⚠ 规则存在但代理 {proxy_name} 不在 proxies 列表里（配置异常）")
elif not rule:
    print(f"✗ 规则未激活（{target_domain} -> {proxy_name}）")
    print("  运行 install 安装配置")
PYEOF
    echo ""
    echo "issuer 验证: curl --proxy http://127.0.0.1:7897 -k -v https://${TARGET_DOMAIN}/v1/models 2>&1 | grep issuer"
}

case "${1:-}" in
    install)   install   ;;
    uninstall) uninstall ;;
    status)    status    ;;
    *)
        echo "用法: $0 install | uninstall | status"
        echo ""
        echo "  install   — 注入代理规则，${TARGET_DOMAIN} 流量走 mitmproxy"
        echo "  uninstall — 移除规则，恢复原始 Clash 配置"
        echo "  status    — 检查规则是否在运行时生效"
        ;;
esac
