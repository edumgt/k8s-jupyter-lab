#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVIRONMENT="dev"
NAMESPACE=""
OUT_DIR="${ROOT_DIR}/dist/backups"
SKIP_MONGO=0

usage() {
  cat <<'EOF'
Usage: bash scripts/backup_platform.sh [options]

Options:
  --env <dev|prod>      Target environment. Defaults to dev.
  --namespace <name>    Override namespace (default: data-platform-<env>).
  --out-dir <path>      Backup output directory root.
  --skip-mongo          Skip MongoDB dump.
  -h, --help            Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_kubectl() {
  if [[ -z "${KUBECONFIG:-}" && -f /etc/kubernetes/admin.conf ]]; then
    env KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
    return
  fi
  kubectl "$@"
}

run_kubectl_ignore_fail() {
  if ! run_kubectl "$@"; then
    return 0
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --skip-mongo)
      SKIP_MONGO=1
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
  *) die "Unsupported environment: ${ENVIRONMENT}" ;;
esac

if [[ -z "${NAMESPACE}" ]]; then
  NAMESPACE="data-platform-${ENVIRONMENT}"
fi

require_command kubectl
require_command date
require_command mkdir
require_command tar

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${OUT_DIR}/${NAMESPACE}-${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

printf 'timestamp=%s\n' "${TIMESTAMP}" > "${BACKUP_DIR}/metadata.env"
printf 'namespace=%s\n' "${NAMESPACE}" >> "${BACKUP_DIR}/metadata.env"
printf 'environment=%s\n' "${ENVIRONMENT}" >> "${BACKUP_DIR}/metadata.env"

run_kubectl get nodes -o wide > "${BACKUP_DIR}/nodes.txt"
run_kubectl get pods -n "${NAMESPACE}" -o wide > "${BACKUP_DIR}/pods.txt"
run_kubectl get svc -n "${NAMESPACE}" -o wide > "${BACKUP_DIR}/services.txt"
run_kubectl get pvc -n "${NAMESPACE}" -o wide > "${BACKUP_DIR}/pvc.txt"
run_kubectl get cm -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/configmaps.yaml"
run_kubectl get secret -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/secrets.yaml"
run_kubectl_ignore_fail get ingress -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/ingress.yaml"

if [[ "${SKIP_MONGO}" != "1" ]]; then
  mongo_pod="$(run_kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${mongo_pod}" ]]; then
    if run_kubectl exec -n "${NAMESPACE}" "${mongo_pod}" -- bash -lc 'command -v mongodump >/dev/null 2>&1'; then
      run_kubectl exec -n "${NAMESPACE}" "${mongo_pod}" -- bash -lc 'mongodump --archive --gzip' > "${BACKUP_DIR}/mongo.archive.gz"
    else
      printf 'warn=mongodump_not_found_in_mongodb_pod\n' >> "${BACKUP_DIR}/metadata.env"
    fi
  else
    printf 'warn=mongodb_pod_not_found\n' >> "${BACKUP_DIR}/metadata.env"
  fi
fi

tar -czf "${BACKUP_DIR}.tar.gz" -C "${OUT_DIR}" "$(basename "${BACKUP_DIR}")"

printf 'Backup directory: %s\n' "${BACKUP_DIR}"
printf 'Backup archive: %s.tar.gz\n' "${BACKUP_DIR}"

