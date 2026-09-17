#!/usr/bin/env python3

import json
import os
import time
import urllib.request

LLM_HOST = os.environ.get("LLM_HOST", "llm:8080")
OUT_FILE = os.environ.get("OUT_FILE", "/data/llm-targets.json")
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "15"))


def log(msg):
    print(msg, flush=True)


first_seen = {}  # model -> epoch seconds when first observed "ready" this load cycle
listed = set()  # models currently written to OUT_FILE, so we only log on change

log(f"polling http://{LLM_HOST}/running every {POLL_INTERVAL}s, writing {OUT_FILE}")

while True:
    try:
        with urllib.request.urlopen(f"http://{LLM_HOST}/running", timeout=5) as r:
            running = json.load(r).get("running", [])
    except Exception as e:
        log(f"could not reach {LLM_HOST}/running: {e}")
        running = []

    ready_now = {m["model"]: m.get("ttl", 0) for m in running if m.get("state") == "ready"}

    # Drop tracking for models no longer ready, so a future reload starts a fresh window.
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

    tmp = OUT_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(targets, f)
    os.replace(tmp, OUT_FILE)

    time.sleep(POLL_INTERVAL)
