#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="dev"
OVERLAY="dev-multinode"
WORKERS_CSV=""
SKIP_RESET=0
SKIP_TAINT=0

usage() {
  cat <<'EOF'
Usage: bash scripts/configure_multinode_cluster.sh [options]

Options:
  --env <dev|prod>         Target environment namespace. Defaults to dev.
  --overlay <path|name>    Overlay path or overlay name under infra/k8s/overlays. Defaults to dev-multinode.
  --workers <csv>          Worker node hostnames (comma-separated), e.g. k8s-worker-1,k8s-worker-2,k8s-worker-3
  --skip-reset             Skip reset_k8s before apply.
  --skip-taint             Skip re-applying control-plane NoSchedule taint.
  -h, --help               Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

run_kubectl() {
  if [[ -n "${KUBECONFIG:-}" ]]; then
    kubectl "$@"
    return
  fi

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
    return
  fi

  kubectl "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --overlay)
      [[ $# -ge 2 ]] || die "--overlay requires a value"
      OVERLAY="$2"
      shift 2
      ;;
    --workers)
      [[ $# -ge 2 ]] || die "--workers requires a value"
      WORKERS_CSV="$2"
      shift 2
      ;;
    --skip-reset)
      SKIP_RESET=1
      shift
      ;;
    --skip-taint)
      SKIP_TAINT=1
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

case "${ENVIRONMENT}" in
  dev|prod) ;;
  *)
    die "Unsupported environment: ${ENVIRONMENT}"
    ;;
esac

if [[ -n "${WORKERS_CSV}" ]]; then
  IFS=',' read -r -a workers <<< "${WORKERS_CSV}"
  for worker in "${workers[@]}"; do
    worker="${worker// /}"
    [[ -n "${worker}" ]] || continue
    run_kubectl label node "${worker}" node-role.kubernetes.io/worker=worker --overwrite
  done
fi

if [[ "${SKIP_TAINT}" == "0" ]]; then
  control_plane_node="$(hostname)"
  run_kubectl taint nodes "${control_plane_node}" node-role.kubernetes.io/control-plane=:NoSchedule --overwrite || true
fi

if [[ "${SKIP_RESET}" == "0" ]]; then
  bash "${ROOT_DIR}/scripts/reset_k8s.sh" --env "${ENVIRONMENT}" --overlay "${OVERLAY}" --skip-runner
fi

bash "${ROOT_DIR}/scripts/apply_k8s.sh" --env "${ENVIRONMENT}" --overlay "${OVERLAY}"

run_kubectl get nodes -o wide
run_kubectl get pods -n "data-platform-${ENVIRONMENT}" -o wide
