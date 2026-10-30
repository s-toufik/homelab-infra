#!/bin/bash
# Applies the "homelab" realm configuration on every `make up`: creates what is missing and resets
# the settings below, so the realm always matches this file (client secrets included).
# Accounts are never created or changed here — that is `make user-*`.
set -euo pipefail

kc="${KCADM:-/opt/keycloak/bin/kcadm.sh}"
cfg=/tmp/kcadm-sync.config
realm=homelab
domain="$HOMELAB_DOMAIN"
work=/tmp/keycloak-sync
mkdir -p "$work"

k() { "$kc" "$@" --config "$cfg"; }

# Keycloak can still answer 503 for a short while after its health check turns green.
attempts=60
for ((i = 1; i <= attempts; i++)); do
  if output="$("$kc" config credentials --config "$cfg" --server "$KEYCLOAK_URL" --realm master \
    --user "$KEYCLOAK_ADMIN_USER" --password "$KEYCLOAK_ADMIN_PASSWORD" 2>&1)"; then
    echo "signed in to Keycloak as $KEYCLOAK_ADMIN_USER"
    break
  fi
  if ((i == attempts)); then
    echo "could not sign in to Keycloak after $attempts attempts, last answer:" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "Keycloak not ready yet (attempt $i/$attempts): ${output##*$'\n'}"
  sleep 2
done

if ! k get "realms/$realm" >/dev/null 2>&1; then
  k create realms -s realm="$realm" -s enabled=true
  echo "realm $realm created"
fi

k update "realms/$realm" \
  -s displayName=Homelab -s enabled=true -s sslRequired=external \
  -s registrationAllowed=false -s resetPasswordAllowed=false -s rememberMe=false \
  -s verifyEmail=false -s loginWithEmailAllowed=false -s duplicateEmailsAllowed=false \
  -s editUsernameAllowed=false \
  -s 'passwordPolicy=length(12) and passwordHistory(5) and forceExpiredPasswordChange(90)' \
  -s bruteForceProtected=true -s permanentLockout=false -s failureFactor=5 \
  -s waitIncrementSeconds=60 -s maxFailureWaitSeconds=900 -s maxDeltaTimeSeconds=43200 \
  -s minimumQuickLoginWaitSeconds=60 -s quickLoginCheckMilliSeconds=1000 \
  -s ssoSessionIdleTimeout=28800 -s ssoSessionMaxLifespan=28800 -s accessTokenLifespan=300
echo "realm $realm settings applied"

if ! k get "roles/admin" -r "$realm" >/dev/null 2>&1; then
  k create roles -r "$realm" -s name=admin -s 'description=Homelab administrator'
  echo "role admin created"
fi

client_uuid() {
  k get clients -r "$realm" -q clientId="$1" --fields id --format csv --noquotes
}

upsert_client() { # clientId, representation file
  local uuid
  uuid="$(client_uuid "$1")"
  if [[ -z "$uuid" ]]; then
    k create clients -r "$realm" -f "$2" >/dev/null
    echo "client $1 created"
  else
    k update "clients/$uuid" -r "$realm" -f "$2"
    echo "client $1 updated"
  fi
}

ensure_mapper() { # clientId, mapper name, mapper file
  local uuid
  uuid="$(client_uuid "$1")"
  if ! k get "clients/$uuid/protocol-mappers/models" -r "$realm" --fields name --format csv --noquotes |
    grep -qx "$2"; then
    k create "clients/$uuid/protocol-mappers/models" -r "$realm" -f "$3" >/dev/null
    echo "mapper $2 added to $1"
  fi
}

# --- oauth2-proxy: the sign-in check in front of homelab-ui and the tools ---
cat >"$work/oauth2-proxy.json" <<JSON
{
  "clientId": "oauth2-proxy",
  "name": "Homelab gateway",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "secret": "$OAUTH2_PROXY_CLIENT_SECRET",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": false,
  "rootUrl": "https://$domain",
  "redirectUris": ["https://$domain/oauth2/callback"],
  "webOrigins": ["https://$domain"],
  "attributes": {
    "pkce.code.challenge.method": "S256",
    "post.logout.redirect.uris": "https://$domain/*"
  }
}
JSON
cat >"$work/oauth2-proxy-audience.json" <<'JSON'
{
  "name": "audience-oauth2-proxy",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "consentRequired": false,
  "config": {
    "included.client.audience": "oauth2-proxy",
    "id.token.claim": "false",
    "access.token.claim": "true"
  }
}
JSON
upsert_client oauth2-proxy "$work/oauth2-proxy.json"
ensure_mapper oauth2-proxy audience-oauth2-proxy "$work/oauth2-proxy-audience.json"

# --- Grafana: signs in with Keycloak itself (realm role "admin" → Grafana Admin) ---
cat >"$work/grafana.json" <<JSON
{
  "clientId": "grafana",
  "name": "Grafana",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "clientAuthenticatorType": "client-secret",
  "secret": "$GRAFANA_OIDC_CLIENT_SECRET",
  "standardFlowEnabled": true,
  "implicitFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "frontchannelLogout": false,
  "rootUrl": "https://$domain:3000",
  "redirectUris": ["https://$domain:3000/login/generic_oauth"],
  "webOrigins": ["https://$domain:3000"],
  "attributes": {
    "pkce.code.challenge.method": "S256",
    "post.logout.redirect.uris": "https://$domain:3000/*"
  }
}
JSON
cat >"$work/grafana-roles.json" <<'JSON'
{
  "name": "realm-roles",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-usermodel-realm-role-mapper",
  "consentRequired": false,
  "config": {
    "claim.name": "roles",
    "multivalued": "true",
    "jsonType.label": "String",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true"
  }
}
JSON
upsert_client grafana "$work/grafana.json"
ensure_mapper grafana realm-roles "$work/grafana-roles.json"

rm -rf "$work" "$cfg"
echo "keycloak sync done"
