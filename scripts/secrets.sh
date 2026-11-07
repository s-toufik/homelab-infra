#!/usr/bin/env bash
source "$(dirname "$0")/_common.sh"

SPECS=(
  "pg-role-postgrest|kubernetes.io/basic-auth|username=postgrest password:24"
  "pg-role-keycloak|kubernetes.io/basic-auth|username=keycloak password:24"
  "keycloak-admin|Opaque|username=admin password:24"
  "oauth2-proxy|Opaque|client-secret:32 cookie-secret:16"
  "grafana-oidc|Opaque|client-secret:32"
  "grafana-admin|Opaque|username=admin password:24"
  "tasker-gateway|Opaque|secret:32"
  "llm-gateway|Opaque|api-key:32"
  "mongodb|Opaque|username=root password:24"
  "mongodb-mcp|Opaque|username=mcp password:24"
  "pg-role-mcp|kubernetes.io/basic-auth|username=mcp password:24"
  "grafana-mcp|Opaque|token?"
  "agent-runtime|Opaque|llm-api-key?"
)

ROTATABLE=(
  pg-role-postgrest/password
  pg-role-keycloak/password
  oauth2-proxy/client-secret
  oauth2-proxy/cookie-secret
  grafana-oidc/client-secret
  tasker-gateway/secret
  llm-gateway/api-key
  mongodb-mcp/password
  pg-role-mcp/password
)

spec_of() {
  local spec
  for spec in "${SPECS[@]}"; do
    [[ "${spec%%|*}" == "$1" ]] && { printf '%s' "$spec"; return 0; }
  done
  return 1
}

stored() { k get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null || true; }

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

write_secret() {
  local name="$1"; shift
  local spec type keys field key value override labels
  spec="$(spec_of "$name")"
  type="$(cut -d'|' -f2 <<<"$spec")"
  keys="$(cut -d'|' -f3 <<<"$spec")"
  labels="    app.kubernetes.io/managed-by: homelab-secrets"
  [[ "$name" == pg-role-* ]] && labels+=$'\n    cnpg.io/reload: "true"'
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n%s\ntype: %s\ndata:\n' \
      "$name" "$NAMESPACE" "$labels" "$type"
    for field in $keys; do
      key="${field%%[:=?]*}"
      value=""
      for override in "$@"; do
        [[ "${override%%=*}" == "$key" ]] && value="$(b64 "${override#*=}")"
      done
      [[ -n "$value" ]] || value="$(stored "$name" "$key")"
      if [[ -z "$value" ]]; then
        case "$field" in
          *:*) value="$(b64 "$(openssl rand -hex "${field#*:}")")" ;;
          *=*) value="$(b64 "${field#*=}")" ;;
          *\?) continue ;;
        esac
      fi
      printf '  %s: %s\n' "$key" "$value"
    done
  } | kubectl apply --server-side --force-conflicts --field-manager=homelab-secrets -f - >/dev/null
}

missing_keys() {
  local spec field key
  spec="$(spec_of "$1")"
  for field in $(cut -d'|' -f3 <<<"$spec"); do
    key="${field%%[:=?]*}"
    [[ -n "$(stored "$1" "$key")" ]] || echo "$key"
  done
}

ensure_namespace() {
  k get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null
}

require_cluster
action="${1:-create}"

case "$action" in
  create)
    command -v openssl >/dev/null || { red "openssl not found"; exit 1; }
    ensure_namespace
    for spec in "${SPECS[@]}"; do
      name="${spec%%|*}"
      if [[ -z "$(missing_keys "$name")" ]]; then
        green "  ✓ $name"
        continue
      fi
      write_secret "$name"
      left="$(missing_keys "$name")"
      if [[ -n "$left" ]]; then
        for key in $left; do yellow "  ! $name/$key is yours to type: make secret-set SECRET=$name KEY=$key"; done
      else
        green "  ✓ $name created"
      fi
    done
    ;;
  check)
    shift
    names=("$@")
    if (( ${#names[@]} == 0 )); then
      for spec in "${SPECS[@]}"; do names+=("${spec%%|*}"); done
    fi
    problems=0
    for name in "${names[@]}"; do
      spec_of "$name" >/dev/null || { red "Unknown Secret '$name'"; exit 1; }
      left="$(missing_keys "$name" | paste -sd ' ' -)"
      [[ -z "$left" ]] && continue
      red "  ✗ Secret $name lacks: $left"
      problems=$((problems + 1))
    done
    (( problems == 0 )) || { red "Run ./scripts/secrets.sh (and secrets.sh set … for typed values) first."; exit 1; }
    ;;
  list)
    k get secrets -l app.kubernetes.io/managed-by=homelab-secrets \
      -o go-template='{{range .items}}{{.metadata.name}}:{{range $k, $v := .data}} {{$k}}{{end}}{{"\n"}}{{end}}'
    ;;
  show)
    template='{{range .items}}{{$n := .metadata.name}}{{range $k, $v := .data}}{{$n}}/{{$k}}: {{$v | base64decode}}{{"\n"}}{{end}}{{end}}'
    k get secrets -l app.kubernetes.io/managed-by=homelab-secrets -o go-template="$template"
    k get secrets postgres-superuser postgres-app --ignore-not-found -o go-template="$template"
    ;;
  set)
    name="${2:-}" key="${3:-}"
    spec_of "$name" >/dev/null || { red "Unknown Secret '$name' (see the list at the top of $0)"; exit 1; }
    cut -d'|' -f3 <<<"$(spec_of "$name")" | tr ' ' '\n' | sed 's/[:=?].*//' | grep -x -- "$key" >/dev/null ||
      { red "Secret $name has no key '$key'"; exit 1; }
    read -r -s -p "Value for $name/$key: " first; echo
    read -r -s -p "Repeat it: " second; echo
    [[ -n "$first" && "$first" == "$second" ]] || { red "Empty, or the two values differ."; exit 1; }
    ensure_namespace
    write_secret "$name" "$key=$first"
    unset first second
    green "  ✓ $name/$key set; the pods using it restart"
    ;;
  rotate)
    name="${2:-}" key="${3:-}"
    printf '%s\n' "${ROTATABLE[@]}" | grep -qx "$name/$key" ||
      { red "Only these can be rotated while running: ${ROTATABLE[*]}"; exit 1; }
    field="$(cut -d'|' -f3 <<<"$(spec_of "$name")" | tr ' ' '\n' | grep "^$key:")"
    write_secret "$name" "$key=$(openssl rand -hex "${field#*:}")"
    green "  ✓ $name/$key replaced; the pods using it restart"
    case "$name/$key" in
      oauth2-proxy/client-secret | grafana-oidc/client-secret)
        yellow "  ! give Keycloak the new client secret: make sync R=keycloak" ;;
      mongodb-mcp/password)
        yellow "  ! give MongoDB the new password: make sync R=mongodb" ;;
    esac
    ;;
  *)
    cat <<EOF
Usage:
  $0                        create what is missing (safe to re-run)
  $0 check [secret…]        exit 1 if a Secret or key is missing
  $0 list                   Secrets and their keys, without values
  $0 show                   every password and key, with its value
  $0 set <secret> <key>     type a value yourself (e.g. agent-runtime llm-api-key)
  $0 rotate <secret> <key>  replace a generated value; the pods using it restart
EOF
    exit 1
    ;;
esac
