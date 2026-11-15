#!/usr/bin/env bash
source "$(dirname "$0")/_common.sh"

action="${1:-}"
selector="${2:-}"
[[ "$action" == restart || "$action" == pull ]] || { red "Usage: $0 restart|pull name=<release>|group=<group>|scope=<scope>"; exit 1; }
[[ -n "$selector" ]] || { red "Usage: make $action R=<release> | G=<group> | S=<scope>"; exit 1; }
require_cluster

releases() {
  if [[ "$selector" == name=* ]]; then
    echo "${selector#name=}"
  else
    helmfile -l "$selector" list --output json | jq -r '.[] | select(.installed == true or .installed == "true") | .name'
  fi
}

workloads_of() {
  k get deploy,statefulset,daemonset -l "app.kubernetes.io/instance=$1" -o name
}

images_of() {
  k get deploy,statefulset,daemonset -l "app.kubernetes.io/instance=$1" \
    -o jsonpath='{range .items[*].spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}'
}

names="$(releases)"
workloads=()
images=()
while read -r release; do
  [[ -n "$release" ]] || continue
  found="$(workloads_of "$release")"
  if [[ -z "$found" ]]; then
    yellow "  - $release: no Deployment, StatefulSet or DaemonSet, skipped"
    continue
  fi
  while read -r workload; do workloads+=("$workload"); done <<< "$found"
  while read -r image; do if [[ -n "$image" ]]; then images+=("$image"); fi; done < <(images_of "$release")
done <<< "$names"

((${#workloads[@]})) || { red "Nothing to $action for $selector"; exit 1; }

if [[ "$action" == pull ]]; then
  while read -r image; do
    echo "==> $image"
    sudo k3s crictl pull "$image"
  done < <(printf '%s\n' "${images[@]}" | sort -u)
  yellow "The pods still run the builds they started with: make restart with the same R=, G= or S= replaces them."
  exit 0
fi

for workload in "${workloads[@]}"; do k rollout restart "$workload"; done
for workload in "${workloads[@]}"; do k rollout status "$workload" --timeout=10m; done
