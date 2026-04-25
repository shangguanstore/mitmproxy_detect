#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 从 config.yaml 读取 upstream_proxy
UPSTREAM=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('config.yaml'))
print(cfg.get('upstream_proxy') or '')
")

# 启动 TLS 包装层（HTTPS CONNECT 代理）
# 客户端设置：Clash proxy server=<server> port=8444 tls=true sni=hxe.7hu.cn
# （安全组直接开放 8444，无需 iptables 重定向）
echo "启动 TLS 代理层（8444）→ mitmproxy 8081"
pkill -f tls_proxy.py 2>/dev/null || true
pkill -f "mitmdump.*traffic_logger" 2>/dev/null || true
sleep 0.3
TLS_PROXY_PORT=8444 nohup python3 tls_proxy.py > /tmp/tls_proxy.log 2>&1 &
echo "TLS proxy PID: $!"

if [ -n "$UPSTREAM" ]; then
    echo "启动 mitmproxy 代理（端口 8081）→ 上游 $UPSTREAM"
    exec mitmdump -s traffic_logger.py --listen-port 8081 --mode "upstream:$UPSTREAM" \
        --set ssl_insecure=true --set termlog_verbosity=warn "$@"
else
    echo "启动 mitmproxy 代理（端口 8081，直连模式）"
    exec mitmdump -s traffic_logger.py --listen-port 8081 \
        --set termlog_verbosity=warn "$@"
fi
