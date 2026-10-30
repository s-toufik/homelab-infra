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
for var in GRAFANA_ADMIN_PASSWORD POSTGRES_PASSWORD POSTGREST_PASSWORD MONGO_ROOT_PASSWORD KAFKA_CLUSTER_ID \
  KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD OAUTH2_PROXY_CLIENT_SECRET OAUTH2_PROXY_COOKIE_SECRET \
  TASKER_GATEWAY_SECRET GRAFANA_OIDC_CLIENT_SECRET LLM_GATEWAY_API_KEY; do
  value="${!var:-}"
  if [[ -z "$value" ]]; then fail "$var is empty (make secrets generates it)"
  elif [[ "$value" == "changeme" ]]; then fail "$var still set to 'changeme' (make secrets generates it)"
  else ok "$var set"; fi
done
for var in POSTGREST_PASSWORD KEYCLOAK_DB_PASSWORD; do
  [[ "${!var:-}" =~ ^[A-Za-z0-9]+$ ]] || fail "$var must use letters and digits only (it is part of a connection string)"
done
case "${#OAUTH2_PROXY_COOKIE_SECRET}" in
  16 | 24 | 32) ok "OAUTH2_PROXY_COOKIE_SECRET has a valid length" ;;
  *) fail "OAUTH2_PROXY_COOKIE_SECRET must be 16, 24 or 32 characters (make secrets generates it)" ;;
esac
if [[ "${HOMELAB_DOMAIN:-}" =~ ^[a-z0-9-]+\.[a-z0-9-]+\.ts\.net$ && "${HOMELAB_DOMAIN}" != *your-tailnet* ]]; then
  ok "HOMELAB_DOMAIN=$HOMELAB_DOMAIN"
else
  fail "HOMELAB_DOMAIN must be this machine's Tailscale name, like <machine>.<tailnet>.ts.net"
fi
# Every published port listens on BIND_ADDR only: it must be this machine's Tailscale address, so the
# stack (agent-runtime and agent-toolbox included) is reachable from the tailnet's devices and nothing else.
# Tailscale addresses are in 100.64.0.0/10, i.e. 100.64.x.x to 100.127.x.x.
if [[ "${BIND_ADDR:-}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [[ -n "$tailscale_ip" && "$tailscale_ip" != "$BIND_ADDR" ]]; then
    fail "BIND_ADDR=$BIND_ADDR but this machine's Tailscale address is $tailscale_ip"
  else
    ok "BIND_ADDR=$BIND_ADDR (Tailscale): published ports are reachable from the tailnet only"
  fi
else
  fail "BIND_ADDR must be this machine's Tailscale address (tailscale ip -4), not '${BIND_ADDR:-}'"
fi

echo "==> Tailscale"
if [[ -S /var/run/tailscale/tailscaled.sock ]]; then
  ok "tailscaled socket present (Caddy gets its certificate there)"
else
  fail "/var/run/tailscale/tailscaled.sock not found: Tailscale must run on this machine"
fi

echo "==> Compose model"
if docker compose config -q; then ok "compose.yml + includes are valid"; else fail "docker compose config failed"; fi

run_check() { # name, docker run args...
  local name="$1"; shift
  if out="$(docker run --rm "$@" 2>&1)"; then ok "$name"; else fail "$name"; echo "$out" | tail -n 20; fi
}

echo "==> Tool configs"
run_check "prometheus.yml (promtool)" \
  -v "$ROOT_DIR/observability/metrics/prometheus:/cfg:ro" --entrypoint promtool \
  "prom/prometheus:${PROMETHEUS_TAG}" check config /cfg/prometheus.yml

run_check "loki config.yml" \
  -v "$ROOT_DIR/observability/logs/loki/config.yml:/etc/loki/config.yml:ro" \
  "grafana/loki:${LOKI_TAG}" -config.file=/etc/loki/config.yml -verify-config

run_check "otel-collector config.yml" \
  -v "$ROOT_DIR/observability/collectors/otel-collector/config.yml:/cfg.yml:ro" \
  "otel/opentelemetry-collector-contrib:${OTELCOL_TAG}" validate --config=/cfg.yml

run_check "config.alloy (syntax)" \
  -v "$ROOT_DIR/observability/collectors/alloy/config.alloy:/cfg.alloy:ro" \
  "grafana/alloy:${ALLOY_TAG}" fmt /cfg.alloy

run_check "Caddyfile (caddy validate)" \
  -v "$ROOT_DIR/gateway/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -e HOMELAB_DOMAIN -e TASKER_GATEWAY_SECRET -e LLM_GATEWAY_API_KEY \
  "caddy:${CADDY_TAG}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

if bash -n gateway/keycloak/sync.sh; then ok "gateway/keycloak/sync.sh (syntax)"; else fail "gateway/keycloak/sync.sh has a syntax error"; fi

echo "==> Database migrations"
for f in repository/postgres/migrations/*.sql; do
  if grep -q '^-- migrate:up' "$f" && grep -q '^-- migrate:down' "$f"; then ok "$f"
  else fail "$f needs both '-- migrate:up' and '-- migrate:down'"; fi
done

echo "==> JSON files (Grafana dashboards, MCP Inspector servers)"
for f in observability/dashboards/grafana/dashboards/*.json ai/mcp-inspector/servers.json; do
  if python3 -m json.tool "$f" >/dev/null 2>&1; then ok "$f"; else fail "$f is not valid JSON"; fi
done

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed."
