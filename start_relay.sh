#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# sudo 会清空 PATH，恢复原用户的 PATH（保留 conda 等环境）
if [ -n "${SUDO_USER:-}" ]; then
    ORIGINAL_PATH=$(sudo -u "$SUDO_USER" bash -l -c 'echo $PATH' 2>/dev/null || echo "")
    if [ -n "$ORIGINAL_PATH" ]; then
        export PATH="$ORIGINAL_PATH:$PATH"
    fi
fi

# 从 config.yaml 读取配置
read_cfg() {
    python -c "
import yaml
cfg = yaml.safe_load(open('config.yaml'))
print(cfg.get('$1', $2))
"
}

HTTP_PORT=$(read_cfg relay_http_port 80)
HTTPS_PORT=$(read_cfg relay_https_port 443)

# 低端口权限提示（不阻止执行，让 mitmdump 自行失败并给出明确报错）
if [ "$HTTP_PORT" -lt 1024 ] || [ "$HTTPS_PORT" -lt 1024 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "[提示] 端口 < 1024 需要权限，若启动失败请运行："
        echo "       sudo -E ./start_relay.sh          # 保留当前环境变量"
        echo "       或: sudo setcap 'cap_net_bind_service=+ep' \$(which mitmdump)"
        echo ""
    fi
fi

echo "[Relay] HTTP  端口: $HTTP_PORT"
echo "[Relay] HTTPS 端口: $HTTPS_PORT"
echo ""

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
python viewer/app.py
