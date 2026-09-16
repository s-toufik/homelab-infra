#!/usr/bin/env bash
# Static checks before deploying: env, compose model, and each tool's own config validator.
source "$(dirname "$0")/_common.sh"

errors=0
fail() { red "  ✗ $*"; errors=$((errors + 1)); }
ok()   { green "  ✓ $*"; }

echo "==> Docker"
command -v docker >/dev/null || { red "docker not found"; exit 1; }
compose_version="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
if [[ -z "$compose_version" ]]; then
  fail "docker compose plugin not found"
elif [[ "$(printf '%s\n2.20.0\n' "$compose_version" | sort -V | head -n1)" != "2.20.0" ]]; then
  fail "docker compose $compose_version < 2.20 (needed for 'include')"
else
  ok "docker compose $compose_version"
fi

echo "==> .env"
load_env
for var in GRAFANA_ADMIN_PASSWORD POSTGRES_PASSWORD MONGO_ROOT_PASSWORD KAFKA_CLUSTER_ID; do
  value="${!var:-}"
  if [[ -z "$value" ]]; then fail "$var is empty"
  elif [[ "$value" == "changeme" ]]; then fail "$var still set to 'changeme'"
  else ok "$var set"; fi
done
[[ "${BIND_ADDR:-}" == "0.0.0.0" ]] && yellow "  ! BIND_ADDR=0.0.0.0: services are reachable from the whole LAN"

echo "==> Compose model"
if docker compose config -q; then ok "compose.yml + includes are valid"; else fail "docker compose config failed"; fi

run_check() { # name, docker run args...
  local name="$1"; shift
  if out="$(docker run --rm "$@" 2>&1)"; then ok "$name"; else fail "$name"; echo "$out" | tail -n 20; fi
}

echo "==> Tool configs"
run_check "prometheus.yml (promtool)" \
  -v "$ROOT_DIR/prometheus:/cfg:ro" --entrypoint promtool \
  "prom/prometheus:${PROMETHEUS_TAG}" check config /cfg/prometheus.yml

run_check "loki config.yml" \
  -v "$ROOT_DIR/loki/config.yml:/etc/loki/config.yml:ro" \
  "grafana/loki:${LOKI_TAG}" -config.file=/etc/loki/config.yml -verify-config

run_check "otel-collector config.yml" \
  -v "$ROOT_DIR/otel-collector/config.yml:/cfg.yml:ro" \
  "otel/opentelemetry-collector-contrib:${OTELCOL_TAG}" validate --config=/cfg.yml

run_check "config.alloy (syntax)" \
  -v "$ROOT_DIR/alloy/config.alloy:/cfg.alloy:ro" \
  "grafana/alloy:${ALLOY_TAG}" fmt /cfg.alloy

echo "==> Grafana dashboards (JSON)"
for f in grafana/dashboards/*.json; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then ok "$f"; else fail "$f is not valid JSON"; fi
done

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed."
