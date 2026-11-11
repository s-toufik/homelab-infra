#!/usr/bin/env bash
source "$(dirname "$0")/_common.sh"

errors=0
fail() { red "  ✗ $*"; errors=$((errors + 1)); }
ok()   { green "  ✓ $*"; }

echo "==> Tools"
for tool in kubectl helm helmfile tailscale jq openssl; do
  if command -v "$tool" >/dev/null; then ok "$tool"; else fail "$tool not found (DevOps guide, Install Kubernetes)"; fi
done
if helm plugin list 2>/dev/null | grep -q '^diff'; then ok "helm diff plugin"; else fail "helm diff plugin missing (DevOps guide, Install Kubernetes)"; fi
docker_config="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
store="$(jq -r '.credsStore // empty' "$docker_config" 2>/dev/null || true)"
if [[ -n "$store" ]] && ! command -v "docker-credential-$store" >/dev/null; then
  fail "$docker_config uses credential helper '$store', which isn't installed: Helm can't pull charts (DevOps guide, Troubleshooting)"
else
  ok "Helm can read the registry logins"
fi

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
if [[ "$(systemctl show tailscaled -p RuntimeDirectoryPreserve --value 2>/dev/null)" =~ ^(restart|yes)$ ]]; then
  ok "tailscaled keeps /run/tailscale when it restarts (Caddy keeps its certificate)"
else
  fail "tailscaled deletes /run/tailscale when it restarts: add RuntimeDirectoryPreserve=restart (DevOps guide, Start Tailscale and SSH at boot)"
fi
if grep -q 'ip daddr 10.250.0.1 drop' /etc/homelab/k3s-lan-guard.nft 2>/dev/null; then
  ok "the LAN guard keeps the node address 10.250.0.1 off the home network"
else
  fail "/etc/homelab/k3s-lan-guard.nft lacks 'ip daddr 10.250.0.1 drop' (DevOps guide, Install Kubernetes, step 4)"
fi
if [[ -d /var/backups/homelab ]]; then ok "/var/backups/homelab exists (the nightly backups go there)"
else fail "/var/backups/homelab is missing: sudo install -d -m 0700 /var/backups/homelab"; fi

echo "==> Secrets"
used=()
while IFS= read -r name; do used+=("$name"); done < <(
  grep -o 'args: \[check, [^]]*\]' helmfile.yaml.gotmpl | sed 's/.*check, //; s/\]//' | tr ',' '\n' | tr -d ' ' | sort -u)
if ./scripts/secrets.sh check "${used[@]}"; then ok "the Secrets the releases use exist (${#used[@]})"; else fail "Secrets missing (above)"; fi

echo "==> Release train"
rendered="${TMPDIR:-/tmp}/helmfile-validate.yaml"
if helmfile template >"$rendered" 2>"${TMPDIR:-/tmp}/helmfile-validate.log"; then
  ok "every release renders (helmfile template)"
  awk 'function flush() { if (doc ~ /(^|\n)kind: (Deployment|StatefulSet|DaemonSet)\n/) printf "---\n%s", doc; doc = "" }
       /^---/ { flush(); next } { doc = doc $0 "\n" } END { flush() }' "$rendered" >"$rendered.workloads"
  if objects="$(kubectl create --dry-run=client -o json -f "$rendered.workloads" 2>"${TMPDIR:-/tmp}/helmfile-validate.log")"; then
    clashes="$(jq -r '
      [ (if .kind == "List" then .items[] else . end)
        | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
        | .metadata.name as $name | .spec.template.spec | (.hostNetwork // false) as $host
        | (.containers + (.initContainers // []))[] | .ports[]?
        | { name: $name, port: (if $host then .containerPort else .hostPort end) }
        | select(.port != null) ]
      | group_by(.port)[] | select(length > 1) | "\(.[0].port) (\(map(.name) | join(", ")))"' <<<"$objects")"
    if [[ -z "$clashes" ]]; then ok "no two pods want the same server port"
    else fail "server ports wanted by two pods: $(paste -sd ' ' <<<"$clashes")"; fi
  else
    fail "kubectl can't read the rendered train:"; sed 's/^/      /' "${TMPDIR:-/tmp}/helmfile-validate.log" >&2
  fi
else
  fail "helmfile template failed:"; sed 's/^/      /' "${TMPDIR:-/tmp}/helmfile-validate.log" >&2
fi
rm -f "$rendered" "$rendered.workloads"

echo "==> Configs"
tag() { awk -v name="$1" '$1 == name ":" { print $2 }' environments/versions.yaml; }
if k run "caddy-validate-$$" --rm -i --quiet --restart=Never --image="caddy:$(tag caddy)" \
  --env="HOMELAB_DOMAIN=$domain" --env=TASKER_GATEWAY_SECRET=placeholder --env=LLM_GATEWAY_API_KEY=placeholder \
  --command -- sh -c 'cat >/tmp/Caddyfile && caddy validate --config /tmp/Caddyfile --adapter caddyfile' \
  <gateway/caddy/Caddyfile >/dev/null 2>"${TMPDIR:-/tmp}/caddy-validate.log"; then
  ok "gateway/caddy/Caddyfile (caddy validate)"
else
  fail "gateway/caddy/Caddyfile:"; sed 's/^/      /' "${TMPDIR:-/tmp}/caddy-validate.log" >&2
fi
if bash -n gateway/keycloak/sync.sh; then ok "gateway/keycloak/sync.sh (syntax)"; else fail "gateway/keycloak/sync.sh has a syntax error"; fi
if jq empty llm/mcp-inspector/servers.json 2>/dev/null; then ok "llm/mcp-inspector/servers.json (JSON)"; else fail "llm/mcp-inspector/servers.json is not valid JSON"; fi
for f in observability/grafana/dashboards/*.json; do
  if jq empty "$f" 2>/dev/null; then ok "$f (JSON)"; else fail "$f is not valid JSON"; fi
done
if python3 -c 'import yaml' 2>/dev/null; then
  if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' llm/llm/config.yml 2>/dev/null; then
    ok "llm/llm/config.yml (YAML)"
  else
    fail "llm/llm/config.yml is not valid YAML"
  fi
fi

check_config() {
  local description="$1" image="$2" file="$3"; shift 3
  local name="validate-$$-$RANDOM" overrides out
  k create configmap "$name" --from-file="$(basename "$file")=$file" >/dev/null
  overrides="$(jq -n --arg name "$name" --arg image "$image" \
    --argjson command "$(printf '%s\n' "$@" | jq -R . | jq -s .)" '{
    spec: {
      restartPolicy: "Never",
      containers: [{ name: "check", image: $image, command: $command,
                     volumeMounts: [{ name: "config", mountPath: "/check" }] }],
      volumes: [{ name: "config", configMap: { name: $name } }]
    }
  }')"
  if out="$(k run "$name" --rm -i --quiet --restart=Never --image="$image" --overrides="$overrides" 2>&1)"; then
    ok "$description"
  else
    fail "$description:"; sed 's/^/      /' <<<"$out" | tail -n 20 >&2
  fi
  k delete configmap "$name" >/dev/null
}
check_config "observability/prometheus/prometheus.yml (promtool)" "prom/prometheus:$(tag prometheus)" \
  observability/prometheus/prometheus.yml /bin/promtool check config /check/prometheus.yml
check_config "observability/loki/config.yml (loki -verify-config)" "grafana/loki:$(tag loki)" \
  observability/loki/config.yml /usr/bin/loki -config.file=/check/config.yml -verify-config
check_config "observability/otel-collector/config.yml (otelcol validate)" \
  "otel/opentelemetry-collector-contrib:$(tag otelCollector)" \
  observability/otel-collector/config.yml /otelcol-contrib validate --config=/check/config.yml
check_config "observability/alloy/config.alloy (alloy fmt)" "grafana/alloy:$(tag alloy)" \
  observability/alloy/config.alloy /bin/alloy fmt /check/config.alloy

echo "==> Database migrations"
for f in repository/db-migrate/migrations/*.sql; do
  if grep -q '^-- migrate:up' "$f" && grep -q '^-- migrate:down' "$f"; then ok "$f"
  else fail "$f needs both '-- migrate:up' and '-- migrate:down'"; fi
done

echo
if (( errors > 0 )); then red "$errors check(s) failed."; exit 1; fi
green "All checks passed — next: make apply"
