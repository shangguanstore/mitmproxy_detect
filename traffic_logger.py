"""
mitmproxy 流量捕获插件
用法: mitmdump -s traffic_logger.py --listen-port 8081
"""

import json
import os
import time
import yaml
from mitmproxy import ctx


def _load_config():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    cfg_path = os.path.join(script_dir, "config.yaml")
    with open(cfg_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f), script_dir


class TrafficLogger:
    def __init__(self):
        self.config, self.script_dir = _load_config()
        log_rel = self.config.get("log_file", "logs/traffic.jsonl")
        self.log_path = os.path.join(self.script_dir, log_rel)
        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)
        self.log_file = open(self.log_path, "a", encoding="utf-8")
        self.target_sites = self.config.get("target_sites") or []
        self.max_body_size = self.config.get("max_body_size", 102400)
        self._pending = {}  # flow.id -> request fields, cleared on response/error
        ctx.log.info(f"[TrafficLogger] 日志文件: {self.log_path}")
        if self.target_sites:
            ctx.log.info(f"[TrafficLogger] 过滤站点: {self.target_sites}")
        else:
            ctx.log.info("[TrafficLogger] 未设置过滤，将捕获所有流量")

    def _should_log(self, flow):
        if not self.target_sites:
            return True
        host = flow.request.pretty_host
        return any(site in host for site in self.target_sites)

    def _safe_text(self, getter):
        try:
            text = getter(strict=False) or ""
            encoded = text.encode("utf-8", errors="replace")
            if len(encoded) > self.max_body_size:
                return text[: self.max_body_size] + f"\n... [已截断，原始 {len(encoded)} 字节]"
            return text
        except Exception:
            return "[二进制或无法解码的内容]"

    def _req_fields(self, flow):
        req = flow.request
        return {
            "id": f"{req.timestamp_start:.6f}",
            "timestamp": req.timestamp_start,
            "datetime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(req.timestamp_start)),
            "host": req.pretty_host,
            "path": req.path,
            "url": req.pretty_url,
            "method": req.method,
            "request_headers": dict(req.headers),
            "request_body": self._safe_text(req.get_text),
            "request_size": len(req.content) if req.content else 0,
        }

    def _write(self, entry):
        self.log_file.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.log_file.flush()

    def request(self, flow):
        if not self._should_log(flow):
            return
        # 请求到达时立即缓存，保证 error() 也能拿到完整请求数据
        self._pending[flow.id] = self._req_fields(flow)

    def response(self, flow):
        base = self._pending.pop(flow.id, None)
        if base is None:
            if not self._should_log(flow):
                return
            base = self._req_fields(flow)

        req = flow.request
        resp = flow.response
        duration_ms = None
        if resp.timestamp_end and req.timestamp_start:
            duration_ms = round((resp.timestamp_end - req.timestamp_start) * 1000, 2)

        entry = {
            **base,
            "status_code": resp.status_code,
            "error": None,
            "response_headers": dict(resp.headers),
            "response_body": self._safe_text(resp.get_text),
            "content_type": resp.headers.get("content-type", ""),
            "duration_ms": duration_ms,
            "response_size": len(resp.content) if resp.content else 0,
        }
        self._write(entry)
        status_color = "✓" if resp.status_code < 400 else "✗"
        ctx.log.info(
            f"{status_color} {req.method:6s} {resp.status_code} "
            f"{req.pretty_url} [{duration_ms}ms]"
        )

    def error(self, flow):
        base = self._pending.pop(flow.id, None)
        if base is None:
            # 没有缓存说明 error 发生在 request 钩子之前（如 CONNECT 隧道建立失败）
            try:
                if not self._should_log(flow):
                    return
                req = flow.request
                if req.method == "CONNECT":
                    # 隧道级别失败，只能拿到目标主机名，没有实际 HTTP 请求
                    host = req.pretty_host
                    base = {
                        "id": f"{req.timestamp_start:.6f}",
                        "timestamp": req.timestamp_start,
                        "datetime": time.strftime(
                            "%Y-%m-%d %H:%M:%S", time.localtime(req.timestamp_start)
                        ),
                        "host": host,
                        "path": "/",
                        "url": f"https://{host}/",
                        "method": "CONNECT",
                        "request_headers": {},
                        "request_body": "",
                        "request_size": 0,
                    }
                else:
                    base = self._req_fields(flow)
            except Exception:
                return

        error_msg = str(flow.error) if flow.error else "未知错误"
        entry = {
            **base,
            "status_code": None,
            "error": error_msg,
            "response_headers": None,
            "response_body": None,
            "content_type": "",
            "duration_ms": None,
            "response_size": 0,
        }
        self._write(entry)
        ctx.log.warn(
            f"✗ {base.get('method', '?'):6s} ERR  "
            f"{base.get('url', '?')} [{error_msg}]"
        )

    def done(self):
        self._pending.clear()
        self.log_file.close()


addons = [TrafficLogger()]
