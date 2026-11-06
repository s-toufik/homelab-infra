#!/usr/bin/env bash
# Downloads llama-swap models ahead of their first use: asks the running llm release to load each
# one (a one-token request through the gateway), which downloads it into its volume. Model names
# and their `-hf <repo>:<quant>` come from llm/llm/config.yml. An on-demand model unloads by itself
# after its ttl.
source "$(dirname "$0")/_common.sh"
require_cluster

CONFIG_FILE="$ROOT_DIR/llm/llm/config.yml"
TIMEOUT_SECONDS=3600
DOMAIN="$(local_value domain)"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <model> [model...]   # download one or more models by name
  $(basename "$0") --all                # download every model in llm/llm/config.yml
  $(basename "$0") --list               # list available model names
EOF
  exit 1
}

list_models() {
  awk '
    /^models:/ { inmodels=1; next }
    /^groups:/ { inmodels=0 }
    inmodels && /^  [A-Za-z0-9_.-]+:/ {
      line=$0; sub(/:.*/,"",line); sub(/^  /,"",line); print line
    }
  ' "$CONFIG_FILE"
}

hf_spec_for() {
  local model="$1"
  awk -v start="  ${model}:" '
    $0 == start { found=1; next }
    found && /^(  [A-Za-z0-9_.-]+:|[a-zA-Z])/ { exit }
    found && /-hf / {
      line=$0; sub(/^[[:space:]]*-hf[[:space:]]+/,"",line); print line
    }
  ' "$CONFIG_FILE"
}

download_one() {
  local model="$1" spec started
  spec="$(hf_spec_for "$model")"
  if [[ -z "$spec" ]]; then
    red "Unknown model: $model (see --list)"
    return 1
  fi

  echo "==> $model ($spec): downloading if needed, then loading (follow it: make logs R=llm)"
  started=$SECONDS
  # The gateway's API key goes to curl on stdin, never on a command line
  if printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" |
    curl -fsS -o /dev/null --max-time "$TIMEOUT_SECONDS" -K - \
      -H 'Content-Type: application/json' \
      -d "{\"model\": \"$model\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}], \"max_tokens\": 1}" \
      "https://$DOMAIN:8090/v1/chat/completions"; then
    green "$model cached and loaded ($(( SECONDS - started ))s)."
  else
    red "$model: failed — see make logs R=llm"
    return 1
  fi
}

[[ $# -gt 0 ]] || usage

case "$1" in
  --list) list_models; exit 0 ;;
  -h|--help) usage ;;
  --all) mapfile -t models < <(list_models) ;;
  *) models=("$@") ;;
esac

API_KEY="$(k get secret llm-gateway -o jsonpath='{.data.api-key}' | base64 -d)"
status=0
for m in "${models[@]}"; do
  download_one "$m" || status=1
done
exit "$status"
