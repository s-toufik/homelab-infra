#!/usr/bin/env bash
# Start the whole stack, or only some services:  ./scripts/up.sh [service...]
source "$(dirname "$0")/_common.sh"
load_env

docker compose up -d --build --remove-orphans "$@"
reload_configs

host="${KAFKA_EXTERNAL_HOST:-localhost}"
[[ "${BIND_ADDR:-127.0.0.1}" == "127.0.0.1" ]] && host=localhost
green "Stack is up."
cat <<INFO

  One sign-in (an account from 'make user-add') for every address below:
  homelab-ui     https://${HOMELAB_DOMAIN}/
  Grafana        https://${HOMELAB_DOMAIN}:3000
  Prometheus     https://${HOMELAB_DOMAIN}:9090
  Kafka UI       https://${HOMELAB_DOMAIN}:8080
  Alloy UI       https://${HOMELAB_DOMAIN}:12345
  LLM            https://${HOMELAB_DOMAIN}:8090/ui   (API: /v1 with LLM_GATEWAY_API_KEY)
  Your account   https://${HOMELAB_DOMAIN}:8443/realms/homelab/account

  OTLP           grpc ${host}:4317 | http ${host}:4318
  Kafka          ${host}:9094
  PostgreSQL     ${host}:5432
  MongoDB        ${host}:27017

INFO
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
