#!/usr/bin/env bash
# Start the whole stack, or only some services:  ./scripts/up.sh [service...]
source "$(dirname "$0")/_common.sh"
load_env

docker compose up -d --build --remove-orphans "$@"

host="${KAFKA_EXTERNAL_HOST:-localhost}"
[[ "${BIND_ADDR:-127.0.0.1}" == "127.0.0.1" ]] && host=localhost
green "Stack is up."
cat <<INFO

  Grafana        http://${host}:3000   (user: ${GRAFANA_ADMIN_USER:-admin})
  Prometheus     http://${host}:9090
  Alloy UI       http://${host}:12345
  Kafka UI       http://${host}:8080
  myapi-a        http://${host}:8001/docs
  myapi-b        http://${host}:8002/docs
  OTLP           grpc ${host}:4317 | http ${host}:4318
  Kafka          ${host}:9094
  PostgreSQL     ${host}:5432
  MongoDB        ${host}:27017

INFO
docker compose ps --format 'table {{.Name}}\t{{.Status}}'
