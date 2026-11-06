#!/usr/bin/env python3
"""llm-sd: tells Prometheus which llama-swap models to scrape (http_sd_configs).

Polls http://<LLM_HOST>/running and serves, on :PORT/targets, one target per model that is ready,
with __metrics_path__ /upstream/<model>/metrics. An on-demand model is listed only during its first
`ttl` seconds after loading: scraping it for longer would reset its idle timer, so it would never
unload. Always-on models (ttl 0) stay listed.
"""

import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LLM_HOST = os.environ.get("LLM_HOST", "llm:8080")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "15"))
PORT = int(os.environ.get("PORT", "8000"))

targets_json = b"[]"
lock = threading.Lock()


def log(msg):
    print(msg, flush=True)


def poll():
    global targets_json
    first_seen = {}
    listed = set()
    while True:
        try:
            with urllib.request.urlopen(f"http://{LLM_HOST}/running", timeout=5) as r:
                running = json.load(r).get("running", [])
        except Exception as e:
            log(f"could not reach {LLM_HOST}/running: {e}")
            running = []

        ready_now = {m["model"]: m.get("ttl", 0) for m in running if m.get("state") == "ready"}

        for model in list(first_seen):
            if model not in ready_now:
                del first_seen[model]

        now = time.time()
        targets = []
        still_listed = set()
        for model, ttl in ready_now.items():
            if model not in first_seen:
                first_seen[model] = now
            elapsed = now - first_seen[model]
            if ttl <= 0 or elapsed < ttl:
                still_listed.add(model)
                targets.append({
                    "targets": [LLM_HOST],
                    "labels": {"model": model, "__metrics_path__": f"/upstream/{model}/metrics"},
                })
            elif model in listed:
                log(f"{model}: ttl ({ttl}s) elapsed since first seen ready, no longer scraping it")

        for model in still_listed - listed:
            log(f"{model}: now ready, scraping its metrics")
        listed = still_listed

        with lock:
            targets_json = json.dumps(targets).encode()
        time.sleep(POLL_INTERVAL)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/targets":
            self.send_error(404)
            return
        with lock:
            body = targets_json
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


log(f"polling http://{LLM_HOST}/running every {POLL_INTERVAL}s, serving :{PORT}/targets")
threading.Thread(target=poll, daemon=True).start()
ThreadingHTTPServer(("", PORT), Handler).serve_forever()
