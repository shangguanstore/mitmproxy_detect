"""
流量日志 Web 查看器
用法: python viewer/app.py
"""

import json
import os
import time
from collections import Counter, defaultdict
from pathlib import Path

import yaml
from flask import Flask, jsonify, render_template, request, Response

app = Flask(__name__)

BASE_DIR = Path(__file__).parent.parent
CONFIG_PATH = BASE_DIR / "config.yaml"


def load_config():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def get_log_path():
    cfg = load_config()
    rel = cfg.get("log_file", "logs/traffic.jsonl")
    return BASE_DIR / rel


# 简单文件缓存，避免每次请求都重新读取大文件
_cache = {"entries": [], "mtime": 0, "size": 0}


def load_entries():
    log_path = get_log_path()
    if not log_path.exists():
        return []
    try:
        stat = log_path.stat()
        if stat.st_mtime == _cache["mtime"] and stat.st_size == _cache["size"]:
            return _cache["entries"]
    except OSError:
        return []

    entries = []
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
                entry.setdefault("_line", i)
                entries.append(entry)
            except json.JSONDecodeError:
                pass

    _cache["entries"] = entries
    _cache["mtime"] = stat.st_mtime
    _cache["size"] = stat.st_size
    return entries


def filter_entries(entries, params):
    domain = params.get("domain", "").strip()
    method = params.get("method", "").strip().upper()
    status_min = params.get("status_min", "")
    status_max = params.get("status_max", "")
    search = params.get("search", "").strip().lower()
    body_search = params.get("body_search", "").strip().lower()
    time_from = params.get("time_from", "")
    time_to = params.get("time_to", "")
    has_error = params.get("has_error", "")

    result = []
    for e in entries:
        if domain and domain.lower() not in e.get("host", "").lower():
            continue
        if method and e.get("method", "").upper() != method:
            continue
        sc = e.get("status_code")
        if status_min and (sc is None or sc < int(status_min)):
            continue
        if status_max and (sc is None or sc > int(status_max)):
            continue
        if search:
            haystack = (e.get("url", "") + e.get("path", "")).lower()
            if search not in haystack:
                continue
        if body_search:
            rb = (e.get("request_body", "") or "").lower()
            resb = (e.get("response_body", "") or "").lower()
            err = (e.get("error", "") or "").lower()
            if body_search not in rb and body_search not in resb and body_search not in err:
                continue
        if time_from:
            try:
                ts_from = float(time_from)
                if e.get("timestamp", 0) < ts_from:
                    continue
            except ValueError:
                pass
        if time_to:
            try:
                ts_to = float(time_to)
                if e.get("timestamp", 0) > ts_to:
                    continue
            except ValueError:
                pass
        if has_error:
            is_err = e.get("error") is not None or (e.get("status_code") or 0) >= 400
            if not is_err:
                continue
        result.append(e)
    return result


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/logs")
def api_logs():
    entries = load_entries()
    filtered = filter_entries(entries, request.args)

    # 排序：最新的在前
    filtered.sort(key=lambda e: e.get("timestamp", 0), reverse=True)

    try:
        page = max(1, int(request.args.get("page", 1)))
        per_page = min(500, max(10, int(request.args.get("per_page", 50))))
    except ValueError:
        page, per_page = 1, 50

    total = len(filtered)
    start = (page - 1) * per_page
    page_data = filtered[start : start + per_page]

    # 只返回列表视图需要的轻量字段
    slim = []
    for e in page_data:
        slim.append(
            {
                "id": e.get("id"),
                "datetime": e.get("datetime"),
                "timestamp": e.get("timestamp"),
                "method": e.get("method"),
                "host": e.get("host"),
                "path": e.get("path", ""),
                "url": e.get("url"),
                "status_code": e.get("status_code"),
                "error": e.get("error"),
                "content_type": e.get("content_type", ""),
                "duration_ms": e.get("duration_ms"),
                "request_size": e.get("request_size", 0),
                "response_size": e.get("response_size", 0),
            }
        )

    return jsonify(
        {
            "total": total,
            "page": page,
            "per_page": per_page,
            "pages": (total + per_page - 1) // per_page if total else 1,
            "items": slim,
        }
    )


@app.route("/api/log/<entry_id>")
def api_log_detail(entry_id):
    entries = load_entries()
    for e in entries:
        if str(e.get("id")) == entry_id:
            return jsonify(e)
    return jsonify({"error": "not found"}), 404


@app.route("/api/stats")
def api_stats():
    entries = load_entries()
    filtered = filter_entries(entries, request.args)

    if not filtered:
        return jsonify(
            {
                "total": 0,
                "domains": [],
                "methods": {},
                "status_dist": {},
                "avg_duration_ms": 0,
                "error_rate": 0,
                "timeline": [],
            }
        )

    domain_counter = Counter(e.get("host", "") for e in filtered)
    method_counter = Counter(e.get("method", "") for e in filtered)

    status_dist = defaultdict(int)
    for e in filtered:
        sc = e.get("status_code")
        if sc is None:
            status_dist["ERR"] += 1
        elif sc < 200:
            status_dist["1xx"] += 1
        elif sc < 300:
            status_dist["2xx"] += 1
        elif sc < 400:
            status_dist["3xx"] += 1
        elif sc < 500:
            status_dist["4xx"] += 1
        else:
            status_dist["5xx"] += 1

    durations = [e["duration_ms"] for e in filtered if e.get("duration_ms") is not None]
    avg_dur = round(sum(durations) / len(durations), 2) if durations else 0

    error_count = sum(1 for e in filtered if e.get("status_code") is None or e.get("status_code", 0) >= 400)
    error_rate = round(error_count / len(filtered) * 100, 1)

    # 时间线：按分钟聚合
    timeline_map = defaultdict(int)
    for e in filtered:
        ts = e.get("timestamp", 0)
        minute_key = int(ts // 60) * 60
        timeline_map[minute_key] += 1
    timeline = [
        {"ts": ts, "label": time.strftime("%H:%M", time.localtime(ts)), "count": cnt}
        for ts, cnt in sorted(timeline_map.items())
    ]

    return jsonify(
        {
            "total": len(filtered),
            "domains": [{"domain": d, "count": c} for d, c in domain_counter.most_common(20)],
            "methods": dict(method_counter),
            "status_dist": dict(status_dist),
            "avg_duration_ms": avg_dur,
            "error_rate": error_rate,
            "timeline": timeline,
        }
    )


@app.route("/api/domains")
def api_domains():
    entries = load_entries()
    domains = sorted(set(e.get("host", "") for e in entries if e.get("host")))
    return jsonify(domains)


@app.route("/api/clear", methods=["POST"])
def api_clear():
    log_path = get_log_path()
    if log_path.exists():
        log_path.write_text("")
    _cache["entries"] = []
    _cache["mtime"] = 0
    _cache["size"] = 0
    return jsonify({"ok": True})


CA_CERT_PATH = Path.home() / ".mitmproxy" / "mitmproxy-ca-cert.pem"


@app.route("/ca")
def ca_cert():
    if not CA_CERT_PATH.exists():
        return "CA 证书未找到，请先启动 mitmproxy 生成证书", 404
    cert_pem = CA_CERT_PATH.read_bytes()
    return Response(
        cert_pem,
        mimetype="application/x-pem-file",
        headers={"Content-Disposition": "attachment; filename=mitmproxy-ca.pem"},
    )


@app.route("/setup")
def setup():
    cfg = load_config()
    port = cfg.get("viewer_port", 8888)
    host = request.host.split(":")[0]
    ca_url = f"http://{host}:{port}/ca"
    html = f"""<!doctype html>
<html lang="zh">
<head><meta charset="utf-8"><title>开发机证书安装</title>
<style>
  body {{ font-family: monospace; max-width: 800px; margin: 40px auto; padding: 0 20px; background:#1e1e1e; color:#d4d4d4; }}
  h2 {{ color: #4ec9b0; }}
  h3 {{ color: #9cdcfe; margin-top: 2em; }}
  pre {{ background:#252526; border:1px solid #3c3c3c; padding:16px; border-radius:6px; overflow-x:auto; position:relative; }}
  .copy-btn {{ position:absolute; top:8px; right:8px; background:#0e639c; color:#fff; border:none; padding:4px 10px; border-radius:4px; cursor:pointer; font-size:12px; }}
  .copy-btn:hover {{ background:#1177bb; }}
  .note {{ color:#ce9178; font-size:13px; margin-top:8px; }}
</style>
</head>
<body>
<h2>开发机一键安装 mitmproxy CA 证书</h2>
<p>在每台开发机上运行对应命令，安装后重启终端即可。</p>

<h3>macOS</h3>
<pre id="mac">curl -s {ca_url} -o /tmp/mitmproxy-ca.pem && \\
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /tmp/mitmproxy-ca.pem && \\
echo 'export NODE_EXTRA_CA_CERTS=/tmp/mitmproxy-ca.pem' >> ~/.zshrc && \\
echo 'done'<button class="copy-btn" onclick="copy('mac')">复制</button></pre>

<h3>Linux (Ubuntu/Debian)</h3>
<pre id="linux">curl -s {ca_url} | sudo tee /usr/local/share/ca-certificates/mitmproxy-ca.crt > /dev/null && \\
sudo update-ca-certificates && \\
echo 'export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mitmproxy-ca.crt' >> ~/.bashrc && \\
echo 'done'<button class="copy-btn" onclick="copy('linux')">复制</button></pre>

<p class="note">NODE_EXTRA_CA_CERTS 让 Claude Code (Node.js) 信任该证书，系统证书库安装让浏览器等应用信任。</p>
<p class="note">CA 证书下载地址：<a href="{ca_url}" style="color:#4ec9b0">{ca_url}</a></p>

<script>
function copy(id) {{
  const text = document.getElementById(id).textContent.replace('复制', '').trim();
  navigator.clipboard.writeText(text).then(() => {{
    const btn = document.querySelector('#' + id + ' .copy-btn');
    btn.textContent = '已复制';
    setTimeout(() => btn.textContent = '复制', 2000);
  }});
}}
</script>
</body>
</html>"""
    return html


if __name__ == "__main__":
    cfg = load_config()
    port = cfg.get("viewer_port", 8888)
    print(f"Web 查看器启动中：http://0.0.0.0:{port}")
    print(f"开发机安装证书：http://0.0.0.0:{port}/setup")
    app.run(host="0.0.0.0", port=port, debug=False)
