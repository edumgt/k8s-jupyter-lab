#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/apply_offline_suite.sh [options]

Options:
  --dry-run   Print commands without executing them.
  -h, --help  Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

run_cmd kubectl apply -k "${ROOT_DIR}/infra/k8s/offline-suite"

if [[ "${DRY_RUN}" != "1" ]]; then
  kubectl get pods -n data-platform-offline
fi
