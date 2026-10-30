#!/usr/bin/env bash
# Writes environments/local.yaml (git-ignored) from this machine's Tailscale status: its name,
# which the gateway answers on, and its address, which every published port listens on.
source "$(dirname "$0")/_common.sh"

command -v tailscale >/dev/null || { red "tailscale not found (DevOps guide, Prepare the server)"; exit 1; }
command -v jq >/dev/null || { red "jq not found: sudo apt install -y jq"; exit 1; }

domain="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
address="$(tailscale ip -4)"
[[ "$domain" == *.ts.net ]] ||
  { red "No Tailscale name ('$domain'): turn on MagicDNS in the Tailscale admin console."; exit 1; }
[[ -n "$address" ]] || { red "No Tailscale address: run sudo tailscale up"; exit 1; }

cat >environments/local.yaml <<EOF
# Written by \`make local\` from this machine's Tailscale status. Not committed.
domain: $domain
tailscaleIP: $address
EOF
green "environments/local.yaml: $domain, $address"
