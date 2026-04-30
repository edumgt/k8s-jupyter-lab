#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="all"
DRY_RUN=0

ENVIRONMENT="${ENVIRONMENT:-dev}"
BUNDLE_DIR="${BUNDLE_DIR:-/opt/k8s-data-platform/offline-bundle}"
WITH_RUNNER=0
IMAGE_REGISTRY="${IMAGE_REGISTRY:-}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-}"
IMAGE_TAG="${IMAGE_TAG:-}"

NODES_CSV="${NODES_CSV:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_STAGING_DIR="${REMOTE_STAGING_DIR:-/tmp/harbor-fill}"
IMPORT_PLATFORM="${IMPORT_PLATFORM:-linux/amd64}"

usage() {
  cat <<'EOF'
Usage: bash scripts/phase2_operate_airgap_cluster.sh [mode] [options]

Mode:
  all               import-and-apply + check (default)
  import-and-apply  import offline bundle images and apply k8s manifests
  check             run readiness/status/harbor image checks
  fill-images       fill missing harbor image refs from bundle tar archives

Options:
  --env dev|prod                Target k8s env (default: dev)
  --bundle-dir PATH             Offline bundle dir (default: /opt/k8s-data-platform/offline-bundle)
  --with-runner                 Apply runner overlay during import-and-apply
  --image-registry HOST         Override registry for apply step
  --image-namespace NAME        Override image namespace for apply step
  --image-tag TAG               Override app image tag for apply step

  --nodes CSV                   Node IP list (for check/fill-images)
  --ssh-user USER               SSH user for check/fill-images (default: ubuntu)
  --ssh-password PASS           SSH password for check/fill-images (default: ubuntu)
  --ssh-key PATH                SSH key path for check/fill-images
  --ssh-port PORT               SSH port for check/fill-images (default: 22)
  --remote-staging-dir PATH     Remote staging dir for fill-images (default: /tmp/harbor-fill)
  --import-platform PLATFORM    fill-images import platform (default: linux/amd64)

  --dry-run                     Print commands only
  -h, --help                    Show this help

Examples:
  bash scripts/phase2_operate_airgap_cluster.sh all --env dev
  bash scripts/phase2_operate_airgap_cluster.sh import-and-apply --bundle-dir /opt/k8s-data-platform/offline-bundle
  bash scripts/phase2_operate_airgap_cluster.sh fill-images --nodes 192.168.56.10,192.168.56.11,192.168.56.12
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

if [[ $# -gt 0 ]]; then
  case "$1" in
    all|import-and-apply|check|fill-images)
      MODE="$1"
      shift
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --with-runner)
      WITH_RUNNER=1
      shift
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
    --nodes)
      [[ $# -ge 2 ]] || die "--nodes requires a value"
      NODES_CSV="$2"
      shift 2
      ;;
    --ssh-user)
      [[ $# -ge 2 ]] || die "--ssh-user requires a value"
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-password)
      [[ $# -ge 2 ]] || die "--ssh-password requires a value"
      SSH_PASSWORD="$2"
      shift 2
      ;;
    --ssh-key)
      [[ $# -ge 2 ]] || die "--ssh-key requires a value"
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port requires a value"
      SSH_PORT="$2"
      shift 2
      ;;
    --remote-staging-dir)
      [[ $# -ge 2 ]] || die "--remote-staging-dir requires a value"
      REMOTE_STAGING_DIR="$2"
      shift 2
      ;;
    --import-platform)
      [[ $# -ge 2 ]] || die "--import-platform requires a value"
      IMPORT_PLATFORM="$2"
      shift 2
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

run_import_and_apply() {
  local cmd=(
    bash "${ROOT_DIR}/scripts/import_offline_bundle.sh"
    --bundle-dir "${BUNDLE_DIR}"
    --env "${ENVIRONMENT}"
    --apply
  )
  if [[ "${WITH_RUNNER}" == "1" ]]; then
    cmd+=(--with-runner)
  fi
  if [[ -n "${IMAGE_REGISTRY}" ]]; then
    cmd+=(--image-registry "${IMAGE_REGISTRY}")
  fi
  if [[ -n "${IMAGE_NAMESPACE}" ]]; then
    cmd+=(--image-namespace "${IMAGE_NAMESPACE}")
  fi
  if [[ -n "${IMAGE_TAG}" ]]; then
    cmd+=(--image-tag "${IMAGE_TAG}")
  fi
  run_cmd "${cmd[@]}"
}

run_checks() {
  run_cmd env BUNDLE_DIR="${BUNDLE_DIR}" bash "${ROOT_DIR}/scripts/check_offline_readiness.sh"
  run_cmd bash "${ROOT_DIR}/scripts/status_k8s.sh" --env "${ENVIRONMENT}"

  local harbor_cmd=(
    bash "${ROOT_DIR}/scripts/check_harbor_stack_images.sh"
    --ssh-user "${SSH_USER}"
    --ssh-port "${SSH_PORT}"
  )
  if [[ -n "${NODES_CSV}" ]]; then
    harbor_cmd+=(--nodes "${NODES_CSV}")
  fi
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    harbor_cmd+=(--ssh-key "${SSH_KEY_PATH}")
  else
    harbor_cmd+=(--ssh-password "${SSH_PASSWORD}")
  fi
  run_cmd "${harbor_cmd[@]}"
}

run_fill_images() {
  local fill_cmd=(
    bash "${ROOT_DIR}/scripts/fill_missing_harbor_images_from_bundle.sh"
    --bundle-dir "${BUNDLE_DIR}"
    --ssh-user "${SSH_USER}"
    --ssh-port "${SSH_PORT}"
    --remote-staging-dir "${REMOTE_STAGING_DIR}"
    --import-platform "${IMPORT_PLATFORM}"
  )
  if [[ -n "${NODES_CSV}" ]]; then
    fill_cmd+=(--nodes "${NODES_CSV}")
  fi
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    fill_cmd+=(--ssh-key "${SSH_KEY_PATH}")
  else
    fill_cmd+=(--ssh-password "${SSH_PASSWORD}")
  fi
  run_cmd "${fill_cmd[@]}"
}

case "${MODE}" in
  all)
    run_import_and_apply
    run_checks
    ;;
  import-and-apply)
    run_import_and_apply
    ;;
  check)
    run_checks
    ;;
  fill-images)
    run_fill_images
    ;;
  *)
    die "Unsupported mode: ${MODE}"
    ;;
esac

