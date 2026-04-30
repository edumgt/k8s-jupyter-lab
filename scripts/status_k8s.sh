#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/kubernetes_runtime.sh
source "${SCRIPT_DIR}/lib/kubernetes_runtime.sh"

ENVIRONMENT="dev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || { printf '--env requires a value\n' >&2; exit 1; }
      ENVIRONMENT="$2"
      shift 2
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

case "${ENVIRONMENT}" in
  dev|prod) ;;
  *)
    printf 'Unsupported environment: %s\n' "${ENVIRONMENT}" >&2
    exit 1
    ;;
esac

NAMESPACE="data-platform-${ENVIRONMENT}"

printf '[host]\n'
hostname
hostname -I || true
printf '\n[code-server]\n'
systemctl --no-pager --full status code-server | sed -n '1,12p' || true
printf '\n[kubernetes]\n'
run_kubectl get nodes
printf '\n[pods]\n'
run_kubectl get pods -n "${NAMESPACE}"
printf '\n[services]\n'
run_kubectl get svc -n "${NAMESPACE}"
printf '\n[pvc]\n'
run_kubectl get pvc -n "${NAMESPACE}"
