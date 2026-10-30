#!/usr/bin/env bash
# Fills every password and secret in .env with a random value (only those still empty or
# "changeme"), then lists what is left to set by hand.
#   ./scripts/secrets.sh                       fill missing secrets
#   ./scripts/secrets.sh --rotate <NAME>       replace one, then run `make up` to apply it
#                                              (OAUTH2_PROXY_COOKIE_SECRET signs everyone out)
source "$(dirname "$0")/_common.sh"

[[ -f .env ]] || { red "Missing .env — run: make env"; exit 1; }
command -v openssl >/dev/null || { red "openssl not found"; exit 1; }

# name:bytes — values are hex, so they are safe in URLs, connection strings and shells
SECRETS=(
  POSTGRES_PASSWORD:24
  MONGO_ROOT_PASSWORD:24
  GRAFANA_ADMIN_PASSWORD:24
  POSTGREST_PASSWORD:24
  KEYCLOAK_ADMIN_PASSWORD:24
  KEYCLOAK_DB_PASSWORD:24
  OAUTH2_PROXY_CLIENT_SECRET:32
  OAUTH2_PROXY_COOKIE_SECRET:16
  TASKER_GATEWAY_SECRET:32
  GRAFANA_OIDC_CLIENT_SECRET:32
  LLM_GATEWAY_API_KEY:32
)
# Database passwords are excluded: changing them needs the running roles updated first.
ROTATABLE=(
  OAUTH2_PROXY_COOKIE_SECRET
  OAUTH2_PROXY_CLIENT_SECRET
  GRAFANA_OIDC_CLIENT_SECRET
  TASKER_GATEWAY_SECRET
  LLM_GATEWAY_API_KEY
)

current_value() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- || true; }

set_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp .env.XXXXXX)"
  chmod 600 "$tmp"
  if grep -qE "^${key}=" .env; then
    awk -v k="$key" -v v="$value" 'index($0, k "=") == 1 { print k "=" v; next } { print }' .env >"$tmp"
  else
    cat .env >"$tmp"
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  mv "$tmp" .env
}

rotate=""
if [[ "${1:-}" == "--rotate" ]]; then
  rotate="${2:-}"
  printf '%s\n' "${ROTATABLE[@]}" | grep -qx "$rotate" ||
    { red "Only these can be rotated safely: ${ROTATABLE[*]}"; exit 1; }
fi

changed=0
for spec in "${SECRETS[@]}"; do
  key="${spec%%:*}"
  bytes="${spec#*:}"
  value="$(current_value "$key")"
  if [[ -n "$rotate" ]]; then
    [[ "$key" == "$rotate" ]] || continue
  elif [[ -n "$value" && "$value" != "changeme" ]]; then
    continue
  fi
  set_value "$key" "$(openssl rand -hex "$bytes")"
  green "  ✓ $key generated"
  changed=$((changed + 1))
done

chmod 600 .env
(( changed > 0 )) || green "  ✓ every generated secret is already set"
if [[ -n "$rotate" ]]; then
  yellow "  ! run 'make up' to apply the new $rotate"
  exit 0
fi

left="$(grep -E '^[A-Z0-9_]+=((changeme)?|.*<[a-z-]+>.*)$' .env | cut -d= -f1 | grep -vx 'LLM_API_KEY' || true)"
grep -qE '^HOMELAB_DOMAIN=.*your-tailnet' .env && left="HOMELAB_DOMAIN"$'\n'"$left"
if [[ -n "${left//$'\n'/}" ]]; then
  yellow "  ! still to set by hand in .env:"
  printf '%s\n' "$left" | sed '/^$/d; s/^/      /'
else
  green "  ✓ nothing left to set by hand — next: make validate"
fi
