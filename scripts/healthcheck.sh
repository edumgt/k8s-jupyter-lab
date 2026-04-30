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

kubernetes_services_ready
run_kubectl get nodes >/dev/null
run_kubectl get pods -n "${NAMESPACE}" >/dev/null
exit 0
