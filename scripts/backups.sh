#!/usr/bin/env bash
# PostgreSQL and MongoDB backups in /var/backups/homelab (root only), made every night by the
# backups release's cron jobs.
#   ./scripts/backups.sh now                         back up both now (the same jobs, run once)
#   ./scripts/backups.sh list                        the backups, newest last
#   ./scripts/backups.sh restore-postgres <file>     REPLACES that database (homelab or keycloak,
#                                                    from the file's name) with the backup
#   ./scripts/backups.sh restore-mongo <file>        REPLACES MongoDB's data with the backup
source "$(dirname "$0")/_common.sh"
require_cluster

DIR=/var/backups/homelab

confirm() { # what will be replaced
  read -r -p "This REPLACES $1. Type 'restore' to confirm: " answer
  [[ "$answer" == restore ]] || { yellow "Aborted."; exit 1; }
}

case "${1:-}" in
  now)
    stamp="$(date +%s)"
    for db in postgres mongodb; do
      k create job "backups-$db-now-$stamp" --from="cronjob/backups-$db" >/dev/null
    done
    for db in postgres mongodb; do
      job="backups-$db-now-$stamp"
      if k wait --for=condition=complete "job/$job" --timeout=15m >/dev/null 2>&1; then
        k logs "job/$job"
        green "  ✓ $db backed up"
      else
        k logs "job/$job" >&2 || true
        red "  ✗ $db backup failed: kubectl -n $NAMESPACE describe job $job"
        exit 1
      fi
      k delete job "$job" --wait=false >/dev/null
    done
    ;;
  list)
    sudo find "$DIR" -type f \( -name '*.dump' -o -name '*.archive' \) -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' | sort
    ;;
  restore-postgres)
    file="${2:?Usage: $0 restore-postgres <file>}"
    sudo test -f "$file" || { red "No file $file (list them: $0 list)"; exit 1; }
    db="$(basename "$file")"; db="${db%%_*}"
    [[ "$db" == homelab || "$db" == keycloak ]] || { red "Can't tell the database from '$file' (homelab_… or keycloak_…)"; exit 1; }
    confirm "PostgreSQL database $db"
    sudo cat "$file" | k exec -i "$(postgres_primary)" -c postgres -- pg_restore --dbname="$db" --clean --if-exists
    green "  ✓ database $db restored from $file"
    if [[ "$db" == homelab ]]; then
      k exec "$(postgres_primary)" -c postgres -- psql -d homelab -qc "NOTIFY pgrst, 'reload schema'"
    else
      yellow "  ! restart Keycloak to drop its caches: kubectl -n $NAMESPACE rollout restart deploy/keycloak"
    fi
    ;;
  restore-mongo)
    file="${2:?Usage: $0 restore-mongo <file>}"
    sudo test -f "$file" || { red "No file $file (list them: $0 list)"; exit 1; }
    confirm "MongoDB's data"
    sudo cat "$file" | k exec -i mongodb-0 -- sh -c \
      'printf "password: \"%s\"\n" "$MONGO_INITDB_ROOT_PASSWORD" >/tmp/mongorestore.yml &&
       mongorestore --username="$MONGO_INITDB_ROOT_USERNAME" --authenticationDatabase=admin \
         --config=/tmp/mongorestore.yml --archive --gzip --drop; status=$?; rm -f /tmp/mongorestore.yml; exit $status'
    green "  ✓ MongoDB restored from $file"
    ;;
  *)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
