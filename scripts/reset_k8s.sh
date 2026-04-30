#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_RUNNER=1
DRY_RUN=0
DELETE_NAMESPACE=0
ENVIRONMENT="dev"
NAMESPACE=""
NAMESPACE_SET=0
OVERLAY_PATH=""
OVERLAY_DIR=""

usage() {
  cat <<'EOF'
Usage: bash scripts/reset_k8s.sh [options]

Options:
  --env <dev|prod>      Delete resources from the selected k8s environment overlay. Defaults to dev.
  --overlay <path|name> Delete a custom overlay path or overlay name under infra/k8s/overlays.
  --namespace <name>    Override namespace used by --delete-namespace.
  --skip-runner         Do not delete the GitLab Runner overlay.
  --delete-namespace    Delete the full selected environment namespace instead of manifest-by-manifest deletion.
  --dry-run             Print commands without executing them.
  -h, --help            Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

set_environment() {
  case "$1" in
    dev|prod)
      ENVIRONMENT="$1"
      if [[ "${NAMESPACE_SET}" == "0" ]]; then
        NAMESPACE="data-platform-${ENVIRONMENT}"
      fi
      ;;
    *)
      die "Unsupported environment: $1 (expected: dev or prod)"
      ;;
  esac
}

resolve_overlay_path() {
  local candidate="$1"

  if [[ -z "${candidate}" ]]; then
    printf '%s\n' "${ROOT_DIR}/infra/k8s/overlays/${ENVIRONMENT}"
    return
  fi

  if [[ "${candidate}" = /* ]]; then
    [[ -d "${candidate}" ]] || die "Overlay directory not found: ${candidate}"
    printf '%s\n' "${candidate}"
    return
  fi

  if [[ -d "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return
  fi

  if [[ -d "${ROOT_DIR}/infra/k8s/overlays/${candidate}" ]]; then
    printf '%s\n' "${ROOT_DIR}/infra/k8s/overlays/${candidate}"
    return
  fi

  die "Overlay not found: ${candidate}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_kubectl_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ kubectl'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  if [[ -z "${KUBECONFIG:-}" && -f /etc/kubernetes/admin.conf ]]; then
    env KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
    return
  fi

  kubectl "$@"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      set_environment "$2"
      shift 2
      ;;
    --overlay)
      [[ $# -ge 2 ]] || die "--overlay requires a value"
      OVERLAY_PATH="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      NAMESPACE="$2"
      NAMESPACE_SET=1
      shift 2
      ;;
    --skip-runner)
      WITH_RUNNER=0
      shift
      ;;
    --delete-namespace)
      DELETE_NAMESPACE=1
      shift
      ;;
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

require_command kubectl
set_environment "${ENVIRONMENT}"
OVERLAY_DIR="$(resolve_overlay_path "${OVERLAY_PATH}")"

if [[ "${DELETE_NAMESPACE}" == "1" ]]; then
  run_kubectl_cmd delete namespace "${NAMESPACE}" --ignore-not-found
  exit 0
fi

if [[ "${WITH_RUNNER}" == "1" ]]; then
  run_kubectl_cmd delete -k "${ROOT_DIR}/infra/k8s/runner/overlays/${ENVIRONMENT}" --ignore-not-found
fi

run_kubectl_cmd delete -k "${OVERLAY_DIR}" --ignore-not-found
