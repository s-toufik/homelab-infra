#!/usr/bin/env bash
# Checks the running homelab after `make apply`: pods, HTTPS, sign-in, the Keycloak password
# policy, the database roles, and that only the Tailscale address publishes ports. Changes nothing.
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
