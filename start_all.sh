#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 从 config.yaml 读取 upstream_proxy
UPSTREAM=$(python3 -c "
import yaml
cfg = yaml.safe_load(open('config.yaml'))
print(cfg.get('upstream_proxy') or '')
")

if [ -n "$UPSTREAM" ]; then
    echo "[代理] 端口 8081 → 上游 $UPSTREAM"
    mitmdump -s traffic_logger.py --listen-port 8081 --mode "upstream:$UPSTREAM" &
else
    echo "[代理] 端口 8081，直连模式"
    mitmdump -s traffic_logger.py --listen-port 8081 &
fi
PROXY_PID=$!
echo "[PID=$PROXY_PID] mitmproxy 已启动"

trap "echo '正在停止代理...'; kill $PROXY_PID 2>/dev/null; exit" INT TERM

python3 viewer/app.py
