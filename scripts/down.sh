#!/usr/bin/env bash
# Stop the stack.
#   ./scripts/down.sh            stop and remove containers (data kept)
#   ./scripts/down.sh --volumes  ALSO DELETE ALL DATA (asks for confirmation)
source "$(dirname "$0")/_common.sh"
load_env

for arg in "$@"; do
  if [[ "$arg" == "-v" || "$arg" == "--volumes" ]]; then
    red "This will permanently delete Prometheus, Loki, Tempo, Grafana, Kafka, PostgreSQL and MongoDB data."
    read -r -p "Type 'delete' to confirm: " answer
    [[ "$answer" == "delete" ]] || { yellow "Aborted."; exit 1; }
  fi
done

docker compose down --remove-orphans "$@"
green "Stack stopped."
