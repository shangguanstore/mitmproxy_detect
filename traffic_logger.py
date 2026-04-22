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

    def response(self, flow):
        if not self._should_log(flow):
            return

        req = flow.request
        resp = flow.response

        duration_ms = None
        if resp.timestamp_end and req.timestamp_start:
            duration_ms = round((resp.timestamp_end - req.timestamp_start) * 1000, 2)

        entry = {
            "id": f"{req.timestamp_start:.6f}",
            "timestamp": req.timestamp_start,
            "datetime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(req.timestamp_start)),
            "host": req.pretty_host,
            "path": req.path,
            "url": req.pretty_url,
            "method": req.method,
            "request_headers": dict(req.headers),
            "request_body": self._safe_text(req.get_text),
            "status_code": resp.status_code,
            "response_headers": dict(resp.headers),
            "response_body": self._safe_text(resp.get_text),
            "content_type": resp.headers.get("content-type", ""),
            "duration_ms": duration_ms,
            "request_size": len(req.content) if req.content else 0,
            "response_size": len(resp.content) if resp.content else 0,
        }

        self.log_file.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.log_file.flush()
        status_color = "✓" if resp.status_code < 400 else "✗"
        ctx.log.info(
            f"{status_color} {req.method:6s} {resp.status_code} "
            f"{req.pretty_url} [{duration_ms}ms]"
        )

    def done(self):
        self.log_file.close()


addons = [TrafficLogger()]
