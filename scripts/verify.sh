#!/usr/bin/env bash
# Checks the running stack after `make up`: HTTPS, sign-in, the Keycloak password policy,
# PostgREST's protection and PostgreSQL row-level security. Changes nothing (test rows are rolled back).
source "$(dirname "$0")/_common.sh"
load_env

errors=0
fail() { red "  ✗ $*"; errors=$((errors + 1)); }
ok()   { green "  ✓ $*"; }
expect() { # description, condition...
  local description="$1"; shift
  if "$@"; then ok "$description"; else fail "$description"; fi
}

domain="${HOMELAB_DOMAIN:?HOMELAB_DOMAIN must be set in .env}"
site="https://${domain}"
signin="https://${domain}:8443"

http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true; }
redirect_to() { curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$@" || true; }
contains() { [[ "$1" == *"$2"* ]]; }
equals() { [[ "$1" == "$2" ]]; }
differs() { [[ "$1" != "$2" ]]; }

psql_homelab() {
  docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -X -q -tA -v ON_ERROR_STOP=1 "$@"
}

echo "==> HTTPS and sign-in"
expect "the gateway answers over HTTPS with a trusted certificate ($site)" \
  equals "$(curl -fsS --max-time 10 "$site/healthz" 2>/dev/null || true)" "OK"
expect "the sign-in check (oauth2-proxy) is up" \
  docker compose exec -T caddy wget -q -T 5 -O /dev/null http://oauth2-proxy:4180/ping
expect "homelab-ui sends signed-out visitors to the sign-in page" \
  contains "$(redirect_to "$site/")" "/oauth2/sign_in"
expect "the Tasker API answers 401 when signed out" \
  equals "$(http_status "$site/api/tasker/workflows")" "401"
expect "the agent API answers 401 when signed out" \
  equals "$(http_status "$site/api/agent/v1/models")" "401"
expect "the old address :8002 redirects to HTTPS" \
  contains "$(redirect_to "http://${domain}:8002/")" "$site/"

echo "==> Keycloak"
issuer="$(curl -fsS --max-time 10 "$signin/realms/homelab/.well-known/openid-configuration" 2>/dev/null |
  python3 -c 'import sys, json; print(json.load(sys.stdin)["issuer"])' 2>/dev/null || true)"
expect "the sign-in service publishes the realm at $signin/realms/homelab" \
  equals "$issuer" "$signin/realms/homelab"
expect "the Keycloak admin console is blocked at the gateway" \
  equals "$(http_status "$signin/admin/")" "403"
realm="$(kcadm get realms/homelab --fields passwordPolicy,bruteForceProtected,registrationAllowed 2>/dev/null |
  python3 -c 'import sys, json
r = json.load(sys.stdin)
print("policy=" + r.get("passwordPolicy", ""))
print("brute_force=" + str(r.get("bruteForceProtected")))
print("registration=" + str(r.get("registrationAllowed")))' 2>/dev/null || true)"
expect "passwords expire after 90 days" contains "$realm" "forceExpiredPasswordChange(90)"
expect "passwords need 12 characters and differ from the last 5" \
  contains "$realm" "length(12) and passwordHistory(5)"
expect "repeated wrong passwords lock the account" contains "$realm" "brute_force=True"
expect "nobody can register an account from the web" contains "$realm" "registration=False"

echo "==> Tools behind the gateway"
for port in 9090 8080 12345 3100 3200 9308; do
  expect "port $port sends signed-out visitors to the sign-in page" \
    contains "$(redirect_to "https://${domain}:${port}/")" "$site/oauth2/sign_in"
done
expect "the LLM playground sends signed-out visitors to the sign-in page" \
  contains "$(redirect_to "https://${domain}:8090/ui")" "$site/oauth2/sign_in"
expect "the LLM API refuses calls without the API key or a session (401)" \
  equals "$(http_status "https://${domain}:8090/v1/models")" "401"
llm_with_key="$(printf 'header = "Authorization: Bearer %s"\n' "$LLM_GATEWAY_API_KEY" |
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "https://${domain}:8090/v1/models" || true)"
expect "the LLM API accepts the API key" equals "$llm_with_key" "200"
expect "plain HTTP on a tool port is refused" differs "$(http_status "http://${domain}:9090/")" "200"
expect "Grafana answers over HTTPS" equals "$(http_status "https://${domain}:3000/api/health")" "200"
expect "Grafana signs in with Keycloak" \
  contains "$(redirect_to "https://${domain}:3000/login/generic_oauth")" "$signin/realms/homelab/protocol/openid-connect/auth"
grafana_client="$(kcadm get clients -r homelab -q clientId=grafana --fields clientId --format csv --noquotes 2>/dev/null || true)"
expect "Keycloak has the Grafana client" equals "$grafana_client" "grafana"
# `docker port` lists only real host bindings (an image's declared EXPOSE ports don't count).
published=""
for container in homelab-ui grafana prometheus kafka-ui alloy loki tempo kafka-exporter llm \
  keycloak oauth2-proxy postgrest; do
  [[ -z "$(docker port "$container" 2>/dev/null || true)" ]] || published+=" $container"
done
expect "only Caddy publishes the web ports (published directly:${published:- none})" equals "$published" ""

echo "==> PostgREST (Tasker API)"
no_secret="$(docker compose exec -T caddy wget -S -q -O /dev/null http://postgrest:3000/workflows 2>&1 || true)"
expect "requests that skip the gateway are refused (403)" contains "$no_secret" " 403 "
no_user="$(docker compose exec -T caddy sh -c \
  'wget -S -q -O /dev/null --header "X-Gateway-Secret: $TASKER_GATEWAY_SECRET" http://postgrest:3000/workflows' 2>&1 || true)"
expect "gateway requests without a signed-in user are refused (401)" contains "$no_user" " 401 "
expect "homelab-ui is reachable behind the gateway" \
  docker compose exec -T caddy wget -q -O /dev/null http://homelab-ui:8080/

echo "==> PostgreSQL"
expect "every migration is applied" \
  docker compose run --rm --no-deps db-migrate status --exit-code
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

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed."
