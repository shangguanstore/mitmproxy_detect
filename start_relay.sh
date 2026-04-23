#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 从 config.yaml 读取配置
read_cfg() {
    python3 -c "
import yaml
cfg = yaml.safe_load(open('config.yaml'))
print(cfg.get('$1', $2))
"
}

HTTP_PORT=$(read_cfg relay_http_port 80)
HTTPS_PORT=$(read_cfg relay_https_port 443)

# 检查端口权限
check_port_permission() {
    local port=$1
    if [ "$port" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
        if ! python3 -c "import socket; s=socket.socket(); s.bind(('', $port)); s.close()" 2>/dev/null; then
            echo "[错误] 端口 $port 需要 root 权限或 cap_net_bind_service"
            echo "       解决方式（二选一）："
            echo "       1. sudo ./start_relay.sh"
            echo "       2. sudo setcap 'cap_net_bind_service=+ep' \$(which mitmdump)"
            exit 1
        fi
    fi
}

check_port_permission "$HTTP_PORT"
check_port_permission "$HTTPS_PORT"

echo "[Relay] HTTP  端口: $HTTP_PORT"
echo "[Relay] HTTPS 端口: $HTTPS_PORT"
echo ""

# 通过环境变量告知插件当前是 relay 模式（无需修改 config.yaml）
export MITM_RELAY_MODE=1

# 启动 HTTP relay
echo "[Relay] 启动 HTTP relay..."
mitmdump -s traffic_logger.py \
    --mode "reverse:http://127.0.0.1:1" \
    --listen-host 0.0.0.0 \
    --listen-port "$HTTP_PORT" \
    --set termlog_verbosity=warn \
    2>&1 | sed 's/^/[HTTP] /' &
HTTP_PID=$!

# 启动 HTTPS relay（mitmproxy 负责 TLS 终结，开发机需信任 mitmproxy CA 证书）
echo "[Relay] 启动 HTTPS relay..."
mitmdump -s traffic_logger.py \
    --mode "reverse:https://127.0.0.1:1" \
    --listen-host 0.0.0.0 \
    --listen-port "$HTTPS_PORT" \
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
    echo "[Relay] 已停止"
    exit 0
}
trap cleanup INT TERM

echo "[Viewer] 启动 Web 查看器..."
python3 viewer/app.py
