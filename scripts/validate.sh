#!/usr/bin/env bash
# Checks before deploying: tools, cluster, environments/local.yaml, Secrets, the release train
# (every release renders) and each tool's own config validator. Changes nothing.
source "$(dirname "$0")/_common.sh"

errors=0
fail() { red "  ✗ $*"; errors=$((errors + 1)); }
ok()   { green "  ✓ $*"; }

echo "==> Tools"
for tool in kubectl helm helmfile tailscale jq openssl; do
  if command -v "$tool" >/dev/null; then ok "$tool"; else fail "$tool not found (DevOps guide, Install Kubernetes)"; fi
done
if helm plugin list 2>/dev/null | grep -q '^diff'; then ok "helm diff plugin"; else fail "helm diff plugin missing (DevOps guide, Install Kubernetes)"; fi

echo "==> Cluster"
require_cluster
ready="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{end}')"
if [[ "$ready" == "True" ]]; then ok "the node is Ready"; else fail "the node is not Ready (kubectl get nodes)"; fi

echo "==> This server (environments/local.yaml)"
domain="$(local_value domain)"
address="$(local_value tailscaleIP)"
actual_domain="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName | rtrimstr(".")' || true)"
actual_address="$(tailscale ip -4 2>/dev/null || true)"
if [[ "$domain" == "$actual_domain" ]]; then ok "domain $domain is this machine's Tailscale name"
else fail "domain '$domain' is not this machine's Tailscale name '$actual_domain' (run: make local)"; fi
if [[ "$address" == "$actual_address" ]]; then ok "tailscaleIP $address is this machine's Tailscale address"
else fail "tailscaleIP '$address' is not this machine's Tailscale address '$actual_address' (run: make local)"; fi
if [[ -S /run/tailscale/tailscaled.sock ]]; then ok "Tailscale's socket is there (Caddy gets its certificate from it)"
else fail "/run/tailscale/tailscaled.sock not found: Tailscale must run on this machine"; fi

echo "==> Secrets"
if ./scripts/secrets.sh check; then ok "every Secret and key exists"; else fail "Secrets missing (above)"; fi

echo "==> Release train"
if helmfile template >/dev/null 2>"${TMPDIR:-/tmp}/helmfile-validate.log"; then
  ok "every release renders (helmfile template)"
else
  fail "helmfile template failed:"; sed 's/^/      /' "${TMPDIR:-/tmp}/helmfile-validate.log" >&2
fi

echo "==> Configs"
caddy_tag="$(awk '/^  caddy:/ { print $2 }' environments/versions.yaml)"
# A throwaway pod runs `caddy validate` on the Caddyfile, sent on stdin; the secrets it reads are
# replaced by placeholders.
if k run "caddy-validate-$$" --rm -i --quiet --restart=Never --image="caddy:${caddy_tag}" \
  --env="HOMELAB_DOMAIN=$domain" --env=TASKER_GATEWAY_SECRET=placeholder --env=LLM_GATEWAY_API_KEY=placeholder \
  --command -- sh -c 'cat >/tmp/Caddyfile && caddy validate --config /tmp/Caddyfile --adapter caddyfile' \
  <gateway/caddy/Caddyfile >/dev/null 2>"${TMPDIR:-/tmp}/caddy-validate.log"; then
  ok "gateway/caddy/Caddyfile (caddy validate)"
else
  fail "gateway/caddy/Caddyfile:"; sed 's/^/      /' "${TMPDIR:-/tmp}/caddy-validate.log" >&2
fi
if bash -n gateway/keycloak/sync.sh; then ok "gateway/keycloak/sync.sh (syntax)"; else fail "gateway/keycloak/sync.sh has a syntax error"; fi

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed — next: make apply"
