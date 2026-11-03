#!/usr/bin/env bash
# Checks the running homelab after `make apply`, one section per release group (the groups of
# helmfile.yaml.gotmpl, `make apply G=<group>`): platform, repository, message-broker,
# observability, gateway, ai, apps. Changes nothing (test rows are rolled back).
source "$(dirname "$0")/_common.sh"
require_cluster

errors=0
fail() { red "  ✗ $*"; errors=$((errors + 1)); }
ok()   { green "  ✓ $*"; }
note() { yellow "  ! $*"; }
expect() { # description, condition... (the condition's own output is hidden)
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else fail "$description"; fi
}

domain="$(local_value domain)"
address="$(local_value tailscaleIP)"
site="https://${domain}"
signin="https://${domain}:8443"

http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
redirect_to() { curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$@" || true; }
contains() { [[ "$1" == *"$2"* ]]; }
equals() { [[ "$1" == "$2" ]]; }
not() { ! "$@"; }
# Fetches a URL from inside the cluster, through the caddy pod (busybox wget)
inside() { k exec deploy/caddy -c caddy -- wget -q -T 5 -O - "$@" 2>/dev/null || true; }
# Number of series a PromQL query returns
series() { inside "http://prometheus:9090/api/v1/query?query=$(jq -rn --arg q "$1" '$q | @uri')" | jq -r '.data.result | length' 2>/dev/null || echo 0; }
positive() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 )); }
psql_homelab() { k exec -i "$(postgres_primary)" -c postgres -- psql -d homelab -X -q -tA -v ON_ERROR_STOP=1 "$@"; }
# Exit 0 if the release's pod opens a TCP connection to host:port (Python in the agents' images,
# Node in the MCP Inspector's)
can_reach() {
  k exec "deploy/$1" -c "$1" -- python -c \
    "import socket, sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 3)" "$2" "$3" >/dev/null 2>&1
}
node_can_reach() {
  k exec "deploy/$1" -c "$1" -- node -e \
    "require('net').connect(+process.argv[2], process.argv[1]).setTimeout(3000, () => process.exit(1))
       .on('connect', () => process.exit(0)).on('error', () => process.exit(1))" "$2" "$3" >/dev/null 2>&1
}

echo "==> platform: operators and pods"
expect "the PostgreSQL operator runs (cnpg-system)" kubectl -n cnpg-system wait --for=condition=Available deploy --all --timeout=10s
expect "Reloader runs: pods restart when their Secrets change (reloader)" kubectl -n reloader wait --for=condition=Available deploy --all --timeout=10s
not_ready="$(k get pods --field-selector=status.phase!=Succeeded \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' |
  awk '$2 != "True" { print $1 }' | paste -sd ' ' -)"
expect "every pod in namespace $NAMESPACE is Ready${not_ready:+ (not ready: $not_ready)}" equals "$not_ready" ""

echo "==> repository: PostgreSQL, PostgREST, MongoDB"
expect "PostgreSQL is Ready" \
  equals "$(k get clusters.postgresql.cnpg.io postgres -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" "True"
expect "its roles match their declaration" \
  equals "$(k get clusters.postgresql.cnpg.io postgres -o jsonpath='{.status.managedRolesStatus.cannotReconcile}' 2>/dev/null)" ""
roles="$(psql_homelab -c "SELECT string_agg(rolname || ':' || rolcanlogin::int || rolsuper::int || rolbypassrls::int, ' ' ORDER BY rolname)
  FROM pg_roles WHERE rolname IN ('keycloak', 'postgrest', 'tasker_web')" 2>/dev/null || true)"
expect "keycloak and postgrest log in without superuser rights, tasker_web cannot log in" \
  equals "$roles" "keycloak:100 postgrest:100 tasker_web:000"
expect "the keycloak database exists" \
  equals "$(k get databases.postgresql.cnpg.io postgres-keycloak -o jsonpath='{.status.applied}' 2>/dev/null)" "true"
files="$(ls repository/postgres/migrations/*.sql | wc -l | tr -d ' ')"
applied="$(psql_homelab -c 'SELECT count(*) FROM public.schema_migrations' 2>/dev/null || true)"
expect "every migration is applied ($applied of $files)" equals "$applied" "$files"
rls="$(psql_homelab 2>&1 <<'SQL' || true
BEGIN;
SET LOCAL ROLE tasker_web;
SELECT set_config('request.headers', '{"remote-user":"verify-alice"}', true) \g /dev/null
INSERT INTO tasker.workflows (id, name) VALUES (gen_random_uuid(), 'verify-rls');
SELECT 'alice=' || count(*) FROM tasker.workflows WHERE name = 'verify-rls';
SELECT set_config('request.headers', '{"remote-user":"verify-bob"}', true) \g /dev/null
SELECT 'bob=' || count(*) FROM tasker.workflows WHERE name = 'verify-rls';
DO $$
BEGIN
    INSERT INTO tasker.workflows (id, owner, name) VALUES (gen_random_uuid(), 'verify-alice', 'verify-forged');
    RAISE NOTICE 'forged=allowed';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'forged=blocked';
END
$$;
ROLLBACK;
SQL
)"
expect "Tasker: a user sees their own workflows" contains "$rls" "alice=1"
expect "Tasker: a user cannot see another user's workflows" contains "$rls" "bob=0"
expect "Tasker: a user cannot write a workflow in another user's name" contains "$rls" "forged=blocked"
no_secret="$(k exec deploy/caddy -c caddy -- wget -S -q -O /dev/null http://postgrest:3000/workflows 2>&1 || true)"
expect "PostgREST refuses requests that skip the gateway (403)" contains "$no_secret" " 403 "
no_user="$(k exec deploy/caddy -c caddy -- sh -c \
  'wget -S -q -O /dev/null --header "X-Gateway-Secret: $TASKER_GATEWAY_SECRET" http://postgrest:3000/workflows' 2>&1 || true)"
expect "PostgREST refuses gateway requests without a signed-in user (401)" contains "$no_user" " 401 "
expect "MongoDB answers" \
  equals "$(k exec mongodb-0 -- mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null || true)" "1"
# 8.x refuses to start on the server's kernel (SERVER-121912)
mongo_image="$(k get statefulset mongodb -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
expect "MongoDB runs 7.0 (${mongo_image:-no mongodb StatefulSet})" contains "$mongo_image" "mongo:7.0"
for db in postgres mongodb; do
  expect "the nightly $db backup is scheduled" k get cronjob "backups-$db"
  last="$(k get cronjob "backups-$db" -o jsonpath='{.status.lastSuccessfulTime}' 2>/dev/null || true)"
  if [[ -z "$last" ]]; then
    note "no $db backup has run yet (make backup runs one now)"
  else
    age=$(( $(date +%s) - $(date -d "$last" +%s) ))
    expect "the last $db backup is less than 26 hours old ($last)" test "$age" -lt 93600
  fi
done

echo "==> message-broker: Kafka, Kafka UI"
expect "Kafka answers" k exec kafka-0 -- /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092
expect "Kafka UI is up" contains "$(inside http://kafka-ui:8080/actuator/health)" '"UP"'

echo "==> observability: Prometheus, Loki, Tempo, OTel Collector, Alloy, Grafana"
targets="$(inside http://prometheus:9090/api/v1/targets)"
down="$(jq -r '[.data.activeTargets[] | select(.health != "up") | .labels.job] | unique | join(" ")' <<<"$targets" 2>/dev/null || echo "?")"
expect "every Prometheus target is up${down:+ (down: $down)}" equals "$down" ""
jobs="$(jq -r '[.data.activeTargets[].labels.job] | unique | join(" ")' <<<"$targets" 2>/dev/null || true)"
for job in prometheus postgres postgrest loki tempo otel-collector alloy grafana kafka-exporter mongodb-exporter llama-cpp; do
  expect "Prometheus scrapes $job" contains " $jobs " " $job "
done
expect "Alloy sends the server's metrics" positive "$(series node_memory_MemTotal_bytes)"
expect "Alloy sends the server's network traffic (its own network, not a pod's)" \
  positive "$(series 'node_network_receive_bytes_total{device=~"en.*|wl.*|eth.*"}')"
expect "Alloy sends every container's metrics" \
  positive "$(series 'container_memory_working_set_bytes{namespace="homelab", container="caddy"}')"
logs="$(inside "http://loki:3100/loki/api/v1/query?query=$(jq -rn '"sum(count_over_time({namespace=\"homelab\"}[10m]))" | @uri')" |
  jq -r '.data.result[0].value[1] // 0' 2>/dev/null || echo 0)"
expect "Loki receives the pods' logs ($logs lines in 10 minutes)" positive "${logs%%.*}"
expect "Tempo is ready" equals "$(inside http://tempo:3200/ready)" "ready"
expect "the OTel Collector is up" contains "$(inside http://otel-collector:13133/)" "Server available"
expect "Grafana is up" contains "$(inside http://grafana:3000/api/health)" '"database": "ok"'

echo "==> gateway: Caddy, Keycloak, oauth2-proxy"
expect "HTTPS answers with a trusted certificate ($site)" \
  equals "$(curl -fsS --max-time 10 "$site/healthz" 2>/dev/null || true)" "OK"
expect "plain HTTP is refused" equals "$(http_status "http://${domain}:443/")" "400"
# Every host port of every pod, as "<hostIP>:<hostPort>"
bindings="$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*].ports[?(@.hostPort)]}{.hostIP}:{.hostPort}{"\n"}{end}{end}' | sort -u)"
others="$(grep -v "^${address}:" <<<"$bindings" | paste -sd ' ' - || true)"
expect "every published port listens on the Tailscale address ${address} only${others:+ (also: $others)}" equals "$others" ""
expect "signed out, the APIs answer 401: health" equals "$(http_status "$site/api/health/caddy")" "401"
expect "signed out, the APIs answer 401: Tasker" equals "$(http_status "$site/api/tasker/workflows")" "401"
expect "signed out, the APIs answer 401: agent" equals "$(http_status "$site/api/agent/v1/models")" "401"
for port in 9090 8080 12345 3100 3200 9308 6274; do
  expect "port $port sends signed-out visitors to the sign-in page" \
    contains "$(redirect_to "https://${domain}:${port}/")" "$site/oauth2/sign_in"
done
expect "Grafana answers over HTTPS" equals "$(http_status "https://${domain}:3000/api/health")" "200"
expect "Grafana signs in with Keycloak" \
  contains "$(redirect_to "https://${domain}:3000/login/generic_oauth")" "$signin/realms/homelab/protocol/openid-connect/auth"
expect "the LLM playground sends signed-out visitors to the sign-in page" \
  contains "$(redirect_to "https://${domain}:8090/ui")" "$site/oauth2/sign_in"
expect "the LLM API refuses calls without the API key or a session (401)" \
  equals "$(http_status "https://${domain}:8090/v1/models")" "401"
# The key goes to curl on stdin, never on a command line
llm_with_key="$(printf 'header = "Authorization: Bearer %s"\n' \
  "$(k get secret llm-gateway -o jsonpath='{.data.api-key}' | base64 -d)" |
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "https://${domain}:8090/v1/models" || true)"
expect "the LLM API accepts the API key" equals "$llm_with_key" "200"
expect "inside the cluster, the Tailscale name reaches the gateway (sign-in checks need it)" \
  k exec deploy/caddy -c caddy -- wget -q -T 5 -O /dev/null "$signin/realms/homelab/.well-known/openid-configuration"
issuer="$(curl -fsS --max-time 10 "$signin/realms/homelab/.well-known/openid-configuration" 2>/dev/null |
  jq -r .issuer 2>/dev/null || true)"
expect "Keycloak publishes the realm at $signin/realms/homelab" equals "$issuer" "$signin/realms/homelab"
expect "the Keycloak admin console is blocked" equals "$(http_status "$signin/admin/")" "403"
expect "the last Keycloak realm sync succeeded" \
  equals "$(k get job keycloak-sync -o jsonpath='{.status.succeeded}' 2>/dev/null)" "1"
realm="$(kcadm get realms/homelab --fields passwordPolicy,bruteForceProtected,registrationAllowed 2>/dev/null |
  jq -r '"policy=\(.passwordPolicy) brute_force=\(.bruteForceProtected) registration=\(.registrationAllowed)"' 2>/dev/null || true)"
expect "passwords expire after 90 days" contains "$realm" "forceExpiredPasswordChange(90)"
expect "passwords need 12 characters and differ from the last 5" contains "$realm" "length(12) and passwordHistory(5)"
expect "repeated wrong passwords lock the account" contains "$realm" "brute_force=true"
expect "nobody can register an account from the web" contains "$realm" "registration=false"

echo "==> ai: LLM, agent-runtime, agent-toolbox, MCP Inspector"
expect "agent-runtime answers on http://${domain}:8000" \
  equals "$(http_status "http://${domain}:8000/actuator/health")" "200"
# The LLM provider agent-runtime is configured with (NVIDIA's API, or the local llm:8080)
llm_url="$(k get deploy agent-runtime -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LLM_BASE_URL")].value}')"
llm_scheme="${llm_url%%://*}"; llm_hostport="${llm_url#*://}"; llm_hostport="${llm_hostport%%/*}"
llm_host="${llm_hostport%%:*}"; llm_port="${llm_hostport##*:}"
[[ "$llm_port" == "$llm_hostport" ]] && { [[ "$llm_scheme" == "https" ]] && llm_port=443 || llm_port=80; }
expect "agent-runtime reaches its LLM provider (${llm_host}:${llm_port})" can_reach agent-runtime "$llm_host" "$llm_port"
expect "agent-runtime reaches agent-toolbox" can_reach agent-runtime agent-toolbox 8001
expect "agent-toolbox answers on http://${domain}:8001 (its host name is allowed)" \
  equals "$(http_status "http://${domain}:8001/actuator/health")" "200"
expect "agent-toolbox reaches the internet" can_reach agent-toolbox integrate.api.nvidia.com 443
expect "agent-toolbox can't reach PostgreSQL" not can_reach agent-toolbox postgres-rw 5432
expect "agent-toolbox can't reach MongoDB" not can_reach agent-toolbox mongodb 27017
expect "agent-toolbox can't reach Kafka" not can_reach agent-toolbox kafka 9092
expect "agent-toolbox can't reach the server itself (its Kubernetes API)" not can_reach agent-toolbox 10.250.0.1 6443
expect "the MCP Inspector reaches agent-toolbox" node_can_reach mcp-inspector agent-toolbox 8001
expect "the MCP Inspector can't reach PostgreSQL" not node_can_reach mcp-inspector postgres-rw 5432
expect "the LLM serves qwen3-8b (always on)" contains "$(inside http://llm:8080/v1/models)" '"qwen3-8b"'
expect "llm-sd lists the loaded models for Prometheus" contains "$(inside http://llm-sd:8000/targets)" '"qwen3-8b"'

echo "==> apps: homelab-ui"
expect "homelab-ui answers behind the gateway" contains "$(inside http://homelab-ui:8080/)" "<app-root"
expect "homelab-ui sends signed-out visitors to the sign-in page" contains "$(redirect_to "$site/")" "/oauth2/sign_in"

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed."
