#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

load_env() {
  if [[ ! -f .env ]]; then
    red "Missing .env — create it with: cp .env.example .env  (then edit the passwords)"
    exit 1
  fi
  # Export so every included compose file sees the variables
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
}

# Runs Keycloak's admin CLI inside the keycloak container, signed in as the bootstrap admin.
# The admin password travels on stdin, so it never appears in the host's process list or in
# `docker inspect`. Arguments are passed to kcadm.sh verbatim.
kcadm() {
  printf '%s\n' "$KEYCLOAK_ADMIN_PASSWORD" |
    docker compose exec -T -e KCADM_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}" keycloak bash -c '
      set -e
      IFS= read -r admin_password
      kc=/opt/keycloak/bin/kcadm.sh
      cfg=/tmp/kcadm-$$.config
      trap "rm -f $cfg" EXIT
      "$kc" config credentials --config "$cfg" --server http://localhost:8080 \
        --realm master --user "$KCADM_ADMIN" --password "$admin_password" >/dev/null
      "$kc" "$@" --config "$cfg"
    ' kcadm "$@"
}

RELOADABLE=(prometheus alloy)

reload_configs() {
  local running service
  running="$(docker compose ps --status running --services)"
  for service in "${RELOADABLE[@]}"; do
    if grep -qx "$service" <<<"$running"; then
      docker compose kill -s SIGHUP "$service" >/dev/null && green "Reloaded $service configuration."
    fi
  done
}
