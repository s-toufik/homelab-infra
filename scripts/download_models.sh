#!/usr/bin/env bash
# Download one or more llama-swap models into the llm-models volume, on demand —
# decoupled from container startup (see llm/config.yml hooks.on_startup.preload
# and llm/README.md). Reads the exact `-hf <repo>:<quant>` spec straight out of
# llm/config.yml and fetches it with the same llama-swap image/binary that
# serves it, so the download lands in the exact cache llama-swap expects.
source "$(dirname "$0")/_common.sh"
load_env

CONFIG_FILE="$ROOT_DIR/llm/config.yml"
VOLUME="homelab_llm-models"
IMAGE="ghcr.io/mostlygeek/llama-swap:${LLAMA_SWAP_TAG:-cpu}"
TIMEOUT_SECONDS=3600

usage() {
  cat <<EOF
Usage:
  $(basename "$0") <model> [model...]   # download one or more models by name
  $(basename "$0") --all                # download every model in llm/config.yml
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
  local model="$1" spec container log_pid waited=0
  spec="$(hf_spec_for "$model")"
  if [[ -z "$spec" ]]; then
    red "Unknown model: $model (see --list)"
    return 1
  fi

  echo "==> $model ($spec)"
  container="model-fetch-$$-${model//./-}"
  docker run -d --rm --name "$container" \
    -v "${VOLUME}:/models" -e LLAMA_CACHE=/models \
    "$IMAGE" /app/llama-server --host 127.0.0.1 --port 8080 -hf "$spec" -c 16 --parallel 1 \
    >/dev/null

  docker logs -f "$container" 2>&1 | sed 's/^/    /' &
  log_pid=$!

  until docker exec "$container" curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; do
    if ! docker ps -q --filter "name=^/${container}\$" | grep -q .; then
      wait "$log_pid" 2>/dev/null || true
      red "$model: container exited before finishing — see log above"
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
    if (( waited > TIMEOUT_SECONDS )); then
      docker stop "$container" >/dev/null 2>&1 || true
      wait "$log_pid" 2>/dev/null || true
      red "$model: timed out after $((TIMEOUT_SECONDS / 60)) minutes"
      return 1
    fi
  done

  docker stop "$container" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true
  green "$model cached."
}

[[ $# -gt 0 ]] || usage

case "$1" in
  --list) list_models; exit 0 ;;
  -h|--help) usage ;;
  --all) mapfile -t models < <(list_models) ;;
  *) models=("$@") ;;
esac

status=0
for m in "${models[@]}"; do
  download_one "$m" || status=1
done
exit "$status"
