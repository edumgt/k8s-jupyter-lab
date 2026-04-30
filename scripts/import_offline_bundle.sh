#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/kubernetes_runtime.sh
source "${SCRIPT_DIR}/lib/kubernetes_runtime.sh"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"

BUNDLE_DIR="${BUNDLE_DIR:-/opt/k8s-data-platform/offline-bundle}"
ENVIRONMENT="dev"
NAMESPACE=""
DRY_RUN=0
IMPORT_DOCKER=1
IMPORT_RUNTIME=1
APPLY_MANIFESTS=0
WITH_RUNNER=0

usage() {
  cat <<'EOF'
Usage: bash scripts/import_offline_bundle.sh [options]

Options:
  --bundle-dir <path>  Offline bundle root directory. Defaults to /opt/k8s-data-platform/offline-bundle.
  --env <dev|prod>     Apply the selected k8s overlay when --apply is used. Defaults to dev.
  --image-registry H   Override image registry host for bundled kustomize apply.
  --image-namespace N  Override image namespace/project for bundled kustomize apply.
  --image-tag TAG      Override app image tag for bundled kustomize apply.
  --apply              Apply the bundled k8s overlay after importing images.
  --with-runner        Apply the bundled GitLab Runner overlay too. Only valid with --apply.
  --docker-only        Import archives into Docker only.
  --runtime-only       Import archives into the Kubernetes container runtime only.
  --dry-run            Print commands without executing them.
  -h, --help           Show this help.
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
      NAMESPACE="data-platform-${ENVIRONMENT}"
      ;;
    *)
      die "Unsupported environment: $1 (expected: dev or prod)"
      ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
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

import_to_runtime() {
  local archive="$1"

  if [[ "${IMPORT_RUNTIME}" != "1" ]]; then
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_runtime_import_cmd "${archive}"
    return 0
  fi

  import_archive_into_runtime "${archive}"
}

apply_bundle_overlay() {
  local overlay_dir="$1"
  local temp_dir=""

  if registry_override_enabled; then
    temp_dir="$(mktemp -d)"
    write_platform_image_override_kustomization "${temp_dir}/kustomization.yaml" "${overlay_dir}"
    run_cmd kubectl apply -k "${temp_dir}"
    rm -rf "${temp_dir}"
    return 0
  fi

  run_cmd kubectl apply -k "${overlay_dir}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      set_environment "$2"
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
    --apply)
      APPLY_MANIFESTS=1
      shift
      ;;
    --with-runner)
      WITH_RUNNER=1
      shift
      ;;
    --docker-only)
      IMPORT_DOCKER=1
      IMPORT_RUNTIME=0
      shift
      ;;
    --runtime-only)
      IMPORT_DOCKER=0
      IMPORT_RUNTIME=1
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

set_environment "${ENVIRONMENT}"

[[ "${IMPORT_DOCKER}" == "1" || "${IMPORT_RUNTIME}" == "1" ]] || die "Nothing to import. Remove conflicting flags."
[[ "${WITH_RUNNER}" != "1" || "${APPLY_MANIFESTS}" == "1" ]] || die "--with-runner requires --apply"

IMAGES_DIR="${BUNDLE_DIR}/images"
K8S_DIR="${BUNDLE_DIR}/k8s"
MANIFEST_DIR="${K8S_DIR}/infra/k8s"

[[ -d "${IMAGES_DIR}" ]] || die "Offline bundle images directory not found: ${IMAGES_DIR}"
[[ -d "${K8S_DIR}" ]] || die "Offline bundle k8s directory not found: ${K8S_DIR}"

if [[ "${IMPORT_DOCKER}" == "1" ]]; then
  require_command docker
fi

if [[ "${IMPORT_RUNTIME}" == "1" ]]; then
  require_runtime_importer
fi

if [[ "${APPLY_MANIFESTS}" == "1" ]]; then
  require_command kubectl
  [[ -d "${MANIFEST_DIR}/overlays/${ENVIRONMENT}" ]] || die "Overlay not found: ${MANIFEST_DIR}/overlays/${ENVIRONMENT}"
fi

mapfile -t archives < <(find "${IMAGES_DIR}" -maxdepth 1 -type f -name '*.tar' | sort)
[[ "${#archives[@]}" -gt 0 ]] || die "No image archives found in ${IMAGES_DIR}"

for archive in "${archives[@]}"; do
  if [[ "${IMPORT_DOCKER}" == "1" ]]; then
    run_cmd docker load -i "${archive}"
  fi
  import_to_runtime "${archive}"
done

if [[ "${APPLY_MANIFESTS}" == "1" ]]; then
  apply_bundle_overlay "${MANIFEST_DIR}/overlays/${ENVIRONMENT}"
  if [[ "${WITH_RUNNER}" == "1" ]]; then
    apply_bundle_overlay "${MANIFEST_DIR}/runner/overlays/${ENVIRONMENT}"
  fi
fi

if [[ "${DRY_RUN}" != "1" && "${APPLY_MANIFESTS}" == "1" ]]; then
  run_kubectl get pods -n "${NAMESPACE}"
fi
