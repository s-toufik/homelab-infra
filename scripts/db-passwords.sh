#!/usr/bin/env bash
# PostgreSQL and MongoDB read their admin password from .env only when their volume is first
# created. These commands check that .env still matches, and bring them back in line.
#   ./scripts/db-passwords.sh check            does .env's password work? (changes nothing)
#   ./scripts/db-passwords.sh postgres-sync    PostgreSQL adopts POSTGRES_PASSWORD from .env
#   ./scripts/db-passwords.sh mongo-sync       MongoDB adopts MONGO_ROOT_PASSWORD (asks the current one)
# Passwords travel inside the script sent on stdin, never on the host's command line.
source "$(dirname "$0")/_common.sh"
load_env

action="${1:-}"
q() { printf '%q' "$1"; }

postgres_check() {
  docker compose exec -T postgres bash -s >/dev/null 2>&1 <<SCRIPT
PGPASSWORD=$(q "$POSTGRES_PASSWORD") psql -X -h 127.0.0.1 -U $(q "$POSTGRES_USER") -d $(q "$POSTGRES_DB") -tAc 'SELECT 1'
SCRIPT
}

postgres_role_exists() {
  docker compose exec -T postgres bash -s >/dev/null 2>&1 <<SCRIPT
psql -X -U $(q "$POSTGRES_USER") -d $(q "$POSTGRES_DB") -tAc 'SELECT 1'
SCRIPT
}

mongo_check() {
  docker compose exec -T mongodb bash -s >/dev/null 2>&1 <<SCRIPT
mongosh --quiet --username $(q "$MONGO_ROOT_USER") --password $(q "$MONGO_ROOT_PASSWORD") \
  --authenticationDatabase admin --eval 'db.adminCommand({ ping: 1 }).ok'
SCRIPT
}

case "$action" in
  check)
    if postgres_check; then
      green "  ✓ PostgreSQL accepts POSTGRES_USER / POSTGRES_PASSWORD from .env"
    elif postgres_role_exists; then
      red "  ✗ PostgreSQL: user '$POSTGRES_USER' exists but POSTGRES_PASSWORD in .env is not its password"
      echo "      fix: make postgres-password-sync"
    else
      red "  ✗ PostgreSQL: no user '$POSTGRES_USER' in database '$POSTGRES_DB'"
      echo "      fix: put back the POSTGRES_USER / POSTGRES_DB the volume was created with"
    fi
    if mongo_check; then
      green "  ✓ MongoDB accepts MONGO_ROOT_USER / MONGO_ROOT_PASSWORD from .env"
    else
      red "  ✗ MongoDB refuses MONGO_ROOT_USER / MONGO_ROOT_PASSWORD from .env"
      echo "      fix: make mongo-password-sync (asks the password MongoDB uses today)"
    fi
    ;;

  postgres-sync)
    postgres_role_exists ||
      { red "No user '$POSTGRES_USER' in database '$POSTGRES_DB': check POSTGRES_USER / POSTGRES_DB in .env."; exit 1; }
    # The container's local socket trusts its own users, so the old password is not needed.
    docker compose exec -T postgres bash -s <<SCRIPT
set -euo pipefail
new_password=$(q "$POSTGRES_PASSWORD")
psql -X -q -v ON_ERROR_STOP=1 -U $(q "$POSTGRES_USER") -d $(q "$POSTGRES_DB") -v new_password="\$new_password" <<'SQL'
ALTER ROLE CURRENT_USER PASSWORD :'new_password';
SQL
SCRIPT
    if postgres_check; then
      green "PostgreSQL now uses POSTGRES_PASSWORD from .env for '$POSTGRES_USER'. Next: make up"
    else
      red "The password was set but a login with it still fails: check the logs (make logs S=postgres)."
      exit 1
    fi
    ;;

  mongo-sync)
    if mongo_check; then green "MongoDB already accepts MONGO_ROOT_PASSWORD from .env."; exit 0; fi
    read -r -s -p "Password MongoDB uses today for '$MONGO_ROOT_USER': " current_password; echo
    docker compose exec -T mongodb bash -s <<SCRIPT
set -euo pipefail
export NEW_PASSWORD=$(q "$MONGO_ROOT_PASSWORD") ROOT_USER=$(q "$MONGO_ROOT_USER")
mongosh --quiet --username "\$ROOT_USER" --password $(q "$current_password") --authenticationDatabase admin \
  --eval 'db.getSiblingDB("admin").changeUserPassword(process.env.ROOT_USER, process.env.NEW_PASSWORD)'
SCRIPT
    unset current_password
    if mongo_check; then
      green "MongoDB now uses MONGO_ROOT_PASSWORD from .env for '$MONGO_ROOT_USER'. Next: make up"
    else
      red "MongoDB still refuses the new password: was the current password right?"
      exit 1
    fi
    ;;

  *)
    echo "Usage: make db-passwords-check | make postgres-password-sync | make mongo-password-sync"
    exit 1
    ;;
esac
