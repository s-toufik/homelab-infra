#!/bin/sh
# Polls llama-swap's safe /running endpoint (no auto-load side effect) and writes
# a Prometheus file_sd target list containing only models currently reported
# "ready". Prometheus's llama-cpp job picks this file up via file_sd_configs, so
# it only ever scrapes an on-demand model's real /upstream/<model>/metrics once
# this poller has already confirmed it's loaded — it never triggers a load itself.
set -eu

LLM_HOST="${LLM_HOST:-llm:8080}"
OUT_FILE="${OUT_FILE:-/data/llm-targets.json}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

while true; do
  running_json=$(curl -fsS --max-time 5 "http://${LLM_HOST}/running" 2>/dev/null || echo '{"running":[]}')

  echo "$running_json" | jq --arg host "$LLM_HOST" -c '
    [.running[]? | select(.state == "ready") | {
      targets: [$host],
      labels: {model: .model, __metrics_path__: ("/upstream/" + .model + "/metrics")}
    }]
  ' > "${OUT_FILE}.tmp" && mv "${OUT_FILE}.tmp" "${OUT_FILE}"

  sleep "$POLL_INTERVAL"
done
