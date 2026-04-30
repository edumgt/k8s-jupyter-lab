#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${ROOT_DIR}/scripts/lib/image_registry.sh"
WITH_RUNNER=0
DRY_RUN=0
ENVIRONMENT="dev"
NAMESPACE=""
NAMESPACE_SET=0
OVERLAY_PATH=""
OVERLAY_DIR=""

usage() {
  cat <<'EOF'
Usage: bash scripts/apply_k8s.sh [options]

Options:
  --env <dev|prod>      Apply the selected k8s environment overlay. Defaults to dev.
  --overlay <path|name> Use a custom overlay path or overlay name under infra/k8s/overlays.
  --namespace <name>    Override namespace shown by the final pod status check.
  --image-registry H    Override image registry host for kustomize apply.
  --image-namespace N   Override image namespace/project for kustomize apply.
  --image-tag TAG       Override app image tag for kustomize apply.
  --with-runner         Apply the optional GitLab Runner k8s overlay too.
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

apply_overlay() {
  local overlay_dir="$1"
  local temp_dir=""

  if registry_override_enabled; then
    temp_dir="$(mktemp -d)"
    write_platform_image_override_kustomization "${temp_dir}/kustomization.yaml" "${overlay_dir}"
    run_kubectl_cmd apply -k "${temp_dir}"
    rm -rf "${temp_dir}"
    return 0
  fi

  run_kubectl_cmd apply -k "${overlay_dir}"
}

annotate_ingress_service_upstream() {
  local namespace="$1"
  local ingress_names=""

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ kubectl -n %q get ingress -o name\n' "${namespace}"
    printf '+ kubectl -n %q annotate ingress <name> nginx.ingress.kubernetes.io/service-upstream=true --overwrite\n' "${namespace}"
    return 0
  fi

  ingress_names="$(run_kubectl_cmd -n "${namespace}" get ingress -o name 2>/dev/null || true)"
  [[ -n "${ingress_names}" ]] || return 0

  while IFS= read -r ingress_name; do
    [[ -n "${ingress_name}" ]] || continue
    run_kubectl_cmd -n "${namespace}" annotate "${ingress_name}" \
      nginx.ingress.kubernetes.io/service-upstream=true --overwrite >/dev/null
  done <<< "${ingress_names}"
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
    --image-registry)
      [[ $# -ge 2 ]] || die "--image-registry requires a value"
      IMAGE_REGISTRY="$2"
      shift 2
      ;;
    --image-namespace)
      [[ $# -ge 2 ]] || die "--image-namespace requires a value"
      IMAGE_NAMESPACE="$2"
      shift 2
      ;;
    --image-tag)
      [[ $# -ge 2 ]] || die "--image-tag requires a value"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --with-runner)
      WITH_RUNNER=1
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

apply_overlay "${OVERLAY_DIR}"
annotate_ingress_service_upstream "${NAMESPACE}"

if [[ "${WITH_RUNNER}" == "1" ]]; then
  apply_overlay "${ROOT_DIR}/infra/k8s/runner/overlays/${ENVIRONMENT}"
fi

if [[ "${DRY_RUN}" != "1" ]]; then
  run_kubectl_cmd get pods -n "${NAMESPACE}"
fi
