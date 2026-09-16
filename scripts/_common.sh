#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

load_env() {
  if [[ ! -f .env ]]; then
    red "Missing .env — create it with: cp .env.example .env  (then edit the passwords)"
    exit 1
  fi
  # Export so every included compose file sees the variables
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
}
