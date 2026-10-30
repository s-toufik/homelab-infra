#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

NAMESPACE=homelab
k() { kubectl --namespace "$NAMESPACE" "$@"; }

require_cluster() {
  command -v kubectl >/dev/null || { red "kubectl not found: install k3s (DevOps guide, Install Kubernetes)"; exit 1; }
  kubectl version --request-timeout=5s >/dev/null 2>&1 ||
    { red "Kubernetes doesn't answer: is k3s running (systemctl status k3s) and KUBECONFIG=/etc/rancher/k3s/k3s.yaml set?"; exit 1; }
}

# A value of environments/local.yaml (written by `make local`)
local_value() {
  [[ -f environments/local.yaml ]] || { red "Missing environments/local.yaml — run: make local"; exit 1; }
  awk -v key="$1" -F': *' '$1 == key { print $2 }' environments/local.yaml | tr -d '"'
}

# The pod running the PostgreSQL primary
postgres_primary() {
  k get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name | head -n1
}

# Runs Keycloak's admin CLI inside the keycloak pod, signed in as its bootstrap admin: the
# password is read there, from the pod's own environment, and never reaches this machine.
# Arguments are passed to kcadm.sh verbatim.
kcadm() {
  k exec -i deploy/keycloak -c keycloak -- bash -c '
    set -e
    kc=/opt/keycloak/bin/kcadm.sh
    cfg=/tmp/kcadm-$$.config
    trap "rm -f $cfg" EXIT
    login=$("$kc" config credentials --config "$cfg" --server http://localhost:8080 --realm master \
      --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" 2>&1) ||
      { echo "$login" >&2; exit 1; }
    "$kc" "$@" --config "$cfg"
  ' kcadm "$@"
}
