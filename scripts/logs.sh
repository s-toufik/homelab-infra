#!/usr/bin/env bash
# Follow logs:  ./scripts/logs.sh [service...]     e.g. ./scripts/logs.sh kafka otel-collector
# TAIL=500 ./scripts/logs.sh grafana
source "$(dirname "$0")/_common.sh"
load_env

docker compose logs -f --tail="${TAIL:-200}" "$@"
