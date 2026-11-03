#!/usr/bin/env bash
# Runs a dbmate command against PostgreSQL in a one-off copy of the db-migrate job (same image,
# migration files and password), prints its output, then deletes it.
#   ./scripts/dbmate.sh status      applied and pending migrations
#   ./scripts/dbmate.sh rollback    undo the latest migration (its migrate:down)
# Applying migrations is `make migrate` (the db-migrate release's own job).
source "$(dirname "$0")/_common.sh"
require_cluster

command="${1:-}"
[[ "$command" == status || "$command" == rollback ]] || { red "Usage: $0 status|rollback"; exit 1; }
k get job db-migrate-migrate >/dev/null 2>&1 ||
  { red "No db-migrate job yet: deploy it first (make apply R=db-migrate)"; exit 1; }

name="db-migrate-$command-$(date +%s)"
k get job db-migrate-migrate -o json | jq --arg name "$name" --arg command "$command" '{
  apiVersion: "batch/v1",
  kind: "Job",
  metadata: { name: $name, labels: { "app.kubernetes.io/part-of": "homelab" } },
  spec: {
    backoffLimit: 0,
    ttlSecondsAfterFinished: 600,
    template: (.spec.template
      | .metadata.labels |= with_entries(select(.key | test("controller-uid|job-name") | not))
      | .spec.containers[0].args = ["--wait", $command])
  }
}' | k create -f - >/dev/null

trap 'k delete job "$name" --wait=false >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 120); do
  state="$(k get job "$name" -o jsonpath='{.status.succeeded}/{.status.failed}')"
  [[ "$state" == 1/* || "$state" == */1 ]] && break
  sleep 1
done
k logs "job/$name"
[[ "$state" == 1/* ]] || { red "dbmate $command failed"; exit 1; }
