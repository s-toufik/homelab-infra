#!/usr/bin/env bash
# Sign-in accounts (Keycloak realm "homelab"), managed from the server's terminal only.
#   ./scripts/users.sh add|password|disable|enable|unlock|admin <account>
#   ./scripts/users.sh list
#   ./scripts/users.sh logout-all
source "$(dirname "$0")/_common.sh"
load_env

REALM=homelab
MIN_LENGTH=12
action="${1:-}"
account="${2:-}"

usage() {
  echo "Usage: make user-add|user-password|user-disable|user-enable|user-unlock|user-admin ACCOUNT=<name>"
  echo "       make users | make sessions-revoke"
  exit 1
}

need_account() {
  [[ -n "$account" ]] || usage
  [[ "$account" =~ ^[a-z0-9][a-z0-9._-]{1,62}$ ]] ||
    { red "Account names use lowercase letters, digits, '.', '_' or '-' (2-63 characters)."; exit 1; }
}

ask() {
  local prompt="$1" value
  read -r -p "$prompt: " value
  [[ -n "$value" ]] || { red "$prompt is required."; exit 1; }
  printf '%s' "$value"
}

ask_password() {
  local first second
  read -r -s -p "New password (at least $MIN_LENGTH characters): " first; echo >&2
  read -r -s -p "Repeat it: " second; echo >&2
  [[ "$first" == "$second" ]] || { red "The passwords differ."; exit 1; }
  (( ${#first} >= MIN_LENGTH )) || { red "The password must have at least $MIN_LENGTH characters."; exit 1; }
  NEW_PASSWORD="$first"
}

user_id() {
  local id
  id="$(kcadm get users -r "$REALM" -q username="$account" -q exact=true --fields id --format csv --noquotes)"
  [[ -n "$id" ]] || { red "No account named '$account'."; exit 1; }
  printf '%s' "$id"
}

# Both passwords travel on stdin, so they never appear in the host's process list, in shell
# history or in `docker inspect`.
set_password() {
  ask_password
  printf '%s\n%s\n' "$KEYCLOAK_ADMIN_PASSWORD" "$NEW_PASSWORD" |
    docker compose exec -T \
      -e KCADM_ADMIN="${KEYCLOAK_ADMIN_USER:-admin}" -e REALM="$REALM" -e ACCOUNT="$account" \
      keycloak bash -c '
        set -e
        IFS= read -r admin_password
        IFS= read -r new_password
        kc=/opt/keycloak/bin/kcadm.sh
        cfg=/tmp/kcadm-$$.config
        trap "rm -f $cfg" EXIT
        "$kc" config credentials --config "$cfg" --server http://localhost:8080 \
          --realm master --user "$KCADM_ADMIN" --password "$admin_password" >/dev/null
        "$kc" set-password --config "$cfg" -r "$REALM" --username "$ACCOUNT" --new-password "$new_password"
      '
  unset NEW_PASSWORD
}

case "$action" in
  add)
    need_account
    email="$(ask "Email")"
    first="$(ask "First name")"
    last="$(ask "Last name")"
    kcadm create users -r "$REALM" \
      -s username="$account" -s enabled=true \
      -s email="$email" -s emailVerified=true \
      -s firstName="$first" -s lastName="$last" >/dev/null
    set_password
    green "Account '$account' created. Its password expires after 90 days."
    ;;
  password)
    need_account
    user_id >/dev/null
    set_password
    green "Password of '$account' changed."
    ;;
  disable | enable)
    need_account
    id="$(user_id)"
    enabled=$([[ "$action" == enable ]] && echo true || echo false)
    kcadm update "users/$id" -r "$REALM" -s enabled="$enabled"
    if [[ "$action" == disable ]]; then
      kcadm create "users/$id/logout" -r "$REALM" >/dev/null
      green "Account '$account' disabled and signed out of Keycloak."
      yellow "Its homelab session ends at its next sign-in check (at most 8 h). Use 'make sessions-revoke' to end it now."
    else
      green "Account '$account' enabled."
    fi
    ;;
  unlock)
    need_account
    id="$(user_id)"
    kcadm delete "attack-detection/brute-force/users/$id" -r "$REALM"
    green "Account '$account' unlocked."
    ;;
  admin)
    need_account
    user_id >/dev/null
    kcadm add-roles -r "$REALM" --uusername "$account" --rolename admin
    green "Account '$account' now has the 'admin' role."
    ;;
  list)
    kcadm get users -r "$REALM" --fields username,email,enabled --format csv --noquotes
    ;;
  logout-all)
    kcadm create logout-all -r "$REALM" >/dev/null
    green "Every Keycloak session of realm '$REALM' ended."
    ;;
  *)
    usage
    ;;
esac
