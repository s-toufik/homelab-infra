#!/usr/bin/env python3
"""Quick tests for the LLM server (llama-swap, one endpoint, models selected by name).

  python3 llm/test.py ask     <base_url> <model> "question"
  python3 llm/test.py tools   <base_url> <model>
  python3 llm/test.py running <base_url>
"""
import json
import sys
import time
import urllib.request


def post(base, payload):
    req = urllib.request.Request(f"{base}/v1/chat/completions", data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    start = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r), time.time() - start


def stats(resp, elapsed):
    u = resp.get("usage", {})
    t = resp.get("timings", {})
    speed = f"{t['predicted_per_second']:.1f} tok/s" if "predicted_per_second" in t else "n/a"
    print(f"\n[{u.get('prompt_tokens')} prompt + {u.get('completion_tokens')} generated tokens, "
          f"{elapsed:.1f}s, generation {speed}]")


def ask(base, model, question):
    resp, elapsed = post(base, {"model": model,
                                "messages": [{"role": "system", "content": "Answer briefly."},
                                             {"role": "user", "content": question}]})
    print(resp["choices"][0]["message"]["content"])
    stats(resp, elapsed)


def tools(base, model):
    tool = {"type": "function", "function": {
        "name": "get_weather",
        "description": "Get the current weather for a city",
        "parameters": {"type": "object",
                       "properties": {"city": {"type": "string"},
                                      "unit": {"type": "string", "enum": ["celsius", "fahrenheit"]}},
                       "required": ["city"]}}}
    resp, elapsed = post(base, {"model": model, "tools": [tool], "tool_choice": "auto",
                                "messages": [{"role": "user", "content": "What's the weather in Paris in celsius?"}]})
    msg = resp["choices"][0]["message"]
    calls = msg.get("tool_calls") or []
    if calls:
        for c in calls:
            print(f"✓ tool call: {c['function']['name']}({c['function']['arguments']})")
    else:
        print("✗ no tool call, model answered:", msg.get("content"))
    stats(resp, elapsed)
    sys.exit(0 if calls else 1)


def running(base):
    with urllib.request.urlopen(f"{base}/v1/models", timeout=10) as r:
        all_models = [m["id"] for m in json.load(r)["data"]]
    with urllib.request.urlopen(f"{base}/running", timeout=10) as r:
        live = {m["model"]: m["state"] for m in json.load(r)["running"]}
    for name in all_models:
        state = live.get(name)
        label = "UP  " if state == "ready" else (state.upper() if state else "DOWN")
        print(f"  {label:<8} {name}")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("ask", "tools", "running"):
        print(__doc__)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "running":
        if len(sys.argv) < 3:
            print(__doc__)
            sys.exit(2)
        running(sys.argv[2])
    elif len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    elif cmd == "ask":
        ask(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "What is Apache Kafka?")
    else:
        tools(sys.argv[2], sys.argv[3])
