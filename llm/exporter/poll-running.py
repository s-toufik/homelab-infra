#!/usr/bin/env python3
"""Polls llama-swap's safe /running endpoint (no auto-load side effect) and writes a
Prometheus file_sd target list. A model is only listed while its own ttl (from /running)
hasn't elapsed since we first saw it "ready" this load cycle -- otherwise our own metrics
scrape would keep resetting its idle timer forever (confirmed: llama-swap counts any
/upstream/<model>/... request, including a metrics GET, as activity, and ignorePaths only
stops it from triggering a *load*, not from resetting ttl on an already-loaded model)."""
import json
import os
import time
import urllib.request

LLM_HOST = os.environ.get("LLM_HOST", "llm:8080")
OUT_FILE = os.environ.get("OUT_FILE", "/data/llm-targets.json")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "15"))

first_seen = {}  # model -> epoch seconds when first observed "ready" this load cycle

while True:
    try:
        with urllib.request.urlopen(f"http://{LLM_HOST}/running", timeout=5) as r:
            running = json.load(r).get("running", [])
    except Exception:
        running = []

    ready_now = {m["model"]: m.get("ttl", 0) for m in running if m.get("state") == "ready"}

    # Drop tracking for models no longer ready, so a future reload starts a fresh window.
    for model in list(first_seen):
        if model not in ready_now:
            del first_seen[model]

    now = time.time()
    targets = []
    for model, ttl in ready_now.items():
        if model not in first_seen:
            first_seen[model] = now
        elapsed = now - first_seen[model]
        if ttl <= 0 or elapsed < ttl:
            targets.append({
                "targets": [LLM_HOST],
                "labels": {"model": model, "__metrics_path__": f"/upstream/{model}/metrics"},
            })

    tmp = OUT_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(targets, f)
    os.replace(tmp, OUT_FILE)

    time.sleep(POLL_INTERVAL)
