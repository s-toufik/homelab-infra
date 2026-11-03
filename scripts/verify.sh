#!/usr/bin/env bash
# Checks the running homelab after `make apply`: pods, HTTPS, sign-in, the Keycloak password
# policy, PostgREST's protection and row-level security, MongoDB and Kafka, the agents' network
# isolation, and that only the Tailscale address publishes ports. Changes nothing (test rows are
# rolled back).
source "$(dirname "$0")/_common.sh"
require_cluster

errors=0
fail() { red "  ✗ $*"; errors=$((errors + 1)); }
ok()   { green "  ✓ $*"; }
expect() { # description, condition...
  local description="$1"; shift
  if "$@"; then ok "$description"; else fail "$description"; fi
}

domain="$(local_value domain)"
address="$(local_value tailscaleIP)"
site="https://${domain}"
signin="https://${domain}:8443"

http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
redirect_to() { curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$@" || true; }
contains() { [[ "$1" == *"$2"* ]]; }
equals() { [[ "$1" == "$2" ]]; }

echo "==> Pods"
not_ready="$(k get pods --field-selector=status.phase!=Succeeded \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' |
  awk '$2 != "True" { print $1 }' | paste -sd ' ' -)"
expect "every pod in namespace $NAMESPACE is Ready${not_ready:+ (not ready: $not_ready)}" equals "$not_ready" ""
expect "PostgreSQL is Ready (CloudNativePG)" \
  equals "$(k get clusters.postgresql.cnpg.io postgres -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" "True"
expect "the database roles match their declaration" \
  equals "$(k get clusters.postgresql.cnpg.io postgres -o jsonpath='{.status.managedRolesStatus.cannotReconcile}' 2>/dev/null)" ""
expect "the keycloak database exists" \
  equals "$(k get databases.postgresql.cnpg.io postgres-keycloak -o jsonpath='{.status.applied}' 2>/dev/null)" "true"
expect "the last Keycloak realm sync succeeded" \
  equals "$(k get job keycloak-sync -o jsonpath='{.status.succeeded}' 2>/dev/null)" "1"

echo "==> HTTPS and sign-in"
expect "the gateway answers over HTTPS with a trusted certificate ($site)" \
  equals "$(curl -fsS --max-time 10 "$site/healthz" 2>/dev/null || true)" "OK"
expect "homelab-ui sends signed-out visitors to the sign-in page" \
  contains "$(redirect_to "$site/")" "/oauth2/sign_in"
expect "the APIs answer 401 when signed out" \
  equals "$(http_status "$site/api/health/caddy")" "401"
expect "inside the cluster, the Tailscale name reaches the gateway (sign-in checks need it)" \
  k exec deploy/caddy -c caddy -- wget -q -T 5 -O /dev/null "$signin/realms/homelab/.well-known/openid-configuration"

echo "==> Keycloak"
issuer="$(curl -fsS --max-time 10 "$signin/realms/homelab/.well-known/openid-configuration" 2>/dev/null |
  jq -r .issuer 2>/dev/null || true)"
expect "the sign-in service publishes the realm at $signin/realms/homelab" equals "$issuer" "$signin/realms/homelab"
expect "the Keycloak admin console is blocked at the gateway" equals "$(http_status "$signin/admin/")" "403"
realm="$(kcadm get realms/homelab --fields passwordPolicy,bruteForceProtected,registrationAllowed 2>/dev/null |
  jq -r '"policy=\(.passwordPolicy) brute_force=\(.bruteForceProtected) registration=\(.registrationAllowed)"' 2>/dev/null || true)"
expect "passwords expire after 90 days" contains "$realm" "forceExpiredPasswordChange(90)"
expect "passwords need 12 characters and differ from the last 5" contains "$realm" "length(12) and passwordHistory(5)"
expect "repeated wrong passwords lock the account" contains "$realm" "brute_force=true"
expect "nobody can register an account from the web" contains "$realm" "registration=false"

psql_homelab() { k exec -i "$(postgres_primary)" -c postgres -- psql -d homelab -X -q -tA -v ON_ERROR_STOP=1 "$@"; }

echo "==> Tasker API (PostgREST) and its database"
expect "the Tasker API answers 401 when signed out" equals "$(http_status "$site/api/tasker/workflows")" "401"
no_secret="$(k exec deploy/caddy -c caddy -- wget -S -q -O /dev/null http://postgrest:3000/workflows 2>&1 || true)"
expect "requests that skip the gateway are refused (403)" contains "$no_secret" " 403 "
no_user="$(k exec deploy/caddy -c caddy -- sh -c \
  'wget -S -q -O /dev/null --header "X-Gateway-Secret: $TASKER_GATEWAY_SECRET" http://postgrest:3000/workflows' 2>&1 || true)"
expect "gateway requests without a signed-in user are refused (401)" contains "$no_user" " 401 "
files="$(ls repository/postgres/migrations/*.sql | wc -l | tr -d ' ')"
applied="$(psql_homelab -c 'SELECT count(*) FROM public.schema_migrations' 2>/dev/null || true)"
expect "every migration is applied ($applied of $files)" equals "$applied" "$files"
roles="$(psql_homelab -c "SELECT string_agg(rolname || ':' || rolcanlogin::int || rolsuper::int || rolbypassrls::int, ' ' ORDER BY rolname)
  FROM pg_roles WHERE rolname IN ('keycloak', 'postgrest', 'tasker_web')" 2>/dev/null || true)"
expect "roles: keycloak and postgrest log in without superuser rights, tasker_web cannot log in" \
  equals "$roles" "keycloak:100 postgrest:100 tasker_web:000"
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
expect "a user sees their own workflows" contains "$rls" "alice=1"
expect "a user cannot see another user's workflows" contains "$rls" "bob=0"
expect "a user cannot write a workflow in another user's name" contains "$rls" "forged=blocked"

echo "==> MongoDB and Kafka"
expect "MongoDB answers" \
  equals "$(k exec mongodb-0 -- mongosh --quiet --eval "db.adminCommand('ping').ok" 2>/dev/null || true)" "1"
expect "Kafka answers" \
  k exec kafka-0 -- /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092
expect "Kafka UI is up" \
  contains "$(k exec deploy/caddy -c caddy -- wget -q -T 5 -O - http://kafka-ui:8080/actuator/health 2>/dev/null || true)" '"UP"'

echo "==> Agent"
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
not() { ! "$@"; }
expect "the agent API answers 401 when signed out" equals "$(http_status "$site/api/agent/v1/models")" "401"
expect "agent-runtime answers on http://${domain}:8000" \
  equals "$(http_status "http://${domain}:8000/actuator/health")" "200"
expect "agent-toolbox answers on http://${domain}:8001 (its host name is allowed)" \
  equals "$(http_status "http://${domain}:8001/actuator/health")" "200"
expect "agent-runtime reaches agent-toolbox" can_reach agent-runtime agent-toolbox 8001
expect "agent-toolbox can't reach PostgreSQL" not can_reach agent-toolbox postgres-rw 5432
expect "agent-toolbox can't reach MongoDB" not can_reach agent-toolbox mongodb 27017
expect "agent-toolbox can't reach Kafka" not can_reach agent-toolbox kafka 9092
expect "agent-toolbox can't reach the server itself (its Kubernetes API)" not can_reach agent-toolbox 10.250.0.1 6443
expect "agent-toolbox reaches the internet" can_reach agent-toolbox integrate.api.nvidia.com 443
expect "the MCP Inspector reaches agent-toolbox" node_can_reach mcp-inspector agent-toolbox 8001
expect "the MCP Inspector can't reach PostgreSQL" not node_can_reach mcp-inspector postgres-rw 5432
# The LLM provider agent-runtime is configured with (NVIDIA's API, or the local llm:8080)
llm_url="$(k get deploy agent-runtime -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="LLM_BASE_URL")].value}')"
llm_scheme="${llm_url%%://*}"; llm_hostport="${llm_url#*://}"; llm_hostport="${llm_hostport%%/*}"
llm_host="${llm_hostport%%:*}"; llm_port="${llm_hostport##*:}"
[[ "$llm_port" == "$llm_hostport" ]] && { [[ "$llm_scheme" == "https" ]] && llm_port=443 || llm_port=80; }
expect "agent-runtime reaches its LLM provider (${llm_host}:${llm_port})" can_reach agent-runtime "$llm_host" "$llm_port"

echo "==> Published ports"
# Every host port of every pod, as "<pod> <hostIP>:<hostPort>"
bindings="$(kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*].ports[?(@.hostPort)]}{.hostIP}:{.hostPort}{"\n"}{end}{end}' | sort -u)"
others="$(grep -v "^${address}:" <<<"$bindings" | paste -sd ' ' - || true)"
expect "every published port listens on the Tailscale address ${address} only${others:+ (also: $others)}" equals "$others" ""
expect "plain HTTP on the gateway's ports is refused" \
  equals "$(http_status "http://${domain}:443/")" "400"

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed."
