#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 从 config.yaml 读取配置
cfg() {
    python -c "import yaml; cfg=yaml.safe_load(open('config.yaml')); print(cfg.get('$1', $2))"
}

HTTP_PORT=$(cfg relay_http_port 80)
HTTPS_PORT=$(cfg relay_https_port 443)
HTTP_INTERNAL=$(cfg relay_http_internal_port 8082)
HTTPS_INTERNAL=$(cfg relay_https_internal_port 8083)

# 如果对外端口 < 1024，用 iptables 重定向到内部高端口（只有 iptables 命令需要 sudo）
IPTABLES_ADDED=0
setup_iptables() {
    echo "[iptables] $HTTP_PORT → $HTTP_INTERNAL (HTTP)"
    echo "[iptables] $HTTPS_PORT → $HTTPS_INTERNAL (HTTPS)"
    sudo iptables -t nat -A PREROUTING -p tcp --dport "$HTTP_PORT"  -j REDIRECT --to-port "$HTTP_INTERNAL"
    sudo iptables -t nat -A PREROUTING -p tcp --dport "$HTTPS_PORT" -j REDIRECT --to-port "$HTTPS_INTERNAL"
    IPTABLES_ADDED=1
}

cleanup_iptables() {
    if [ "$IPTABLES_ADDED" -eq 1 ]; then
        echo "[iptables] 清理规则..."
        sudo iptables -t nat -D PREROUTING -p tcp --dport "$HTTP_PORT"  -j REDIRECT --to-port "$HTTP_INTERNAL" 2>/dev/null || true
        sudo iptables -t nat -D PREROUTING -p tcp --dport "$HTTPS_PORT" -j REDIRECT --to-port "$HTTPS_INTERNAL" 2>/dev/null || true
    fi
}

if [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTPS_PORT" -lt 1024 ]; then
    setup_iptables
    LISTEN_HTTP=$HTTP_INTERNAL
    LISTEN_HTTPS=$HTTPS_INTERNAL
else
    LISTEN_HTTP=$HTTP_PORT
    LISTEN_HTTPS=$HTTPS_PORT
fi

echo ""
echo "[Relay] 对外端口  : HTTP=$HTTP_PORT  HTTPS=$HTTPS_PORT"
echo "[Relay] 监听端口  : HTTP=$LISTEN_HTTP  HTTPS=$LISTEN_HTTPS"
echo ""

export MITM_RELAY_MODE=1

# 启动 HTTP relay
echo "[Relay] 启动 HTTP relay..."
mitmdump -s traffic_logger.py \
    --mode "reverse:http://127.0.0.1:1" \
    --listen-host 0.0.0.0 \
    --listen-port "$LISTEN_HTTP" \
    --set termlog_verbosity=warn \
    2>&1 | sed 's/^/[HTTP] /' &
HTTP_PID=$!

# 启动 HTTPS relay（mitmproxy 负责 TLS 终结，开发机需信任 mitmproxy CA 证书）
echo "[Relay] 启动 HTTPS relay..."
mitmdump -s traffic_logger.py \
    --mode "reverse:https://127.0.0.1:1" \
    --listen-host 0.0.0.0 \
    --listen-port "$LISTEN_HTTPS" \
    --set termlog_verbosity=warn \
    --set upstream_cert=false \
    2>&1 | sed 's/^/[HTTPS] /' &
HTTPS_PID=$!

echo "[PID] HTTP=$HTTP_PID  HTTPS=$HTTPS_PID"
echo ""

cleanup() {
    echo ""
    echo "[Relay] 正在停止..."
    kill "$HTTP_PID" "$HTTPS_PID" 2>/dev/null || true
    wait "$HTTP_PID" "$HTTPS_PID" 2>/dev/null || true
    cleanup_iptables
    echo "[Relay] 已停止"
    exit 0
}
trap cleanup INT TERM

echo "[Viewer] 启动 Web 查看器..."
python viewer/app.py
