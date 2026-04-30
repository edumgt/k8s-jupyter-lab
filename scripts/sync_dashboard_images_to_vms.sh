#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"

SYNC_SCRIPT="${ROOT_DIR}/scripts/sync_docker_image_to_vms.sh"

SOURCE_UI_IMAGE="${SOURCE_UI_IMAGE:-ghcr.io/headlamp-k8s/headlamp:v0.38.0}"
TARGET_UI_IMAGE="${TARGET_UI_IMAGE:-$(platform_support_image platform-headlamp v0.38.0)}"
ALLOW_UPSTREAM_PULL=0

SYNC_ARGS=()

usage() {
  cat <<'EOF'
Usage: bash scripts/sync_dashboard_images_to_vms.sh [options]

Retags the cluster UI image to the platform registry naming scheme and copies
it from this WSL host into VM Docker/containerd caches.

This script keeps its original filename for backward compatibility, but it now
syncs Headlamp instead of Kubernetes Dashboard.

By default, this script does NOT pull from upstream registries. Prepare the
source image locally first (for example via scripts/build_k8s_images.sh), or
pass --allow-upstream-pull explicitly.

Options:
  --source-ui-image REF        Source Headlamp image (default: ghcr.io/headlamp-k8s/headlamp:v0.38.0)
  --target-ui-image REF        Target image tag to preload on VMs.
  --allow-upstream-pull        Pull missing source image from upstream registry.

  The options below are forwarded to scripts/sync_docker_image_to_vms.sh:
  --vars-file PATH
  --control-plane-ip IP
  --worker1-ip IP
  --worker2-ip IP
  --worker3-ip IP
  --remote-archive PATH
  --ssh-user USER
  --ssh-password PASS
  --ssh-key-path PATH
  --ssh-port PORT
  --skip-containerd-import

  -h, --help                   Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_source_image() {
  local source_ref="$1"
  if docker image inspect "${source_ref}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${ALLOW_UPSTREAM_PULL}" == "1" ]]; then
    docker pull "${source_ref}"
    return 0
  fi

  die "Source image missing locally: ${source_ref}. Prepare it first or use --allow-upstream-pull."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-ui-image)
      [[ $# -ge 2 ]] || die "--source-ui-image requires a value"
      SOURCE_UI_IMAGE="$2"
      shift 2
      ;;
    --target-ui-image)
      [[ $# -ge 2 ]] || die "--target-ui-image requires a value"
      TARGET_UI_IMAGE="$2"
      shift 2
      ;;
    --allow-upstream-pull)
      ALLOW_UPSTREAM_PULL=1
      shift
      ;;
    --vars-file|--control-plane-ip|--worker1-ip|--worker2-ip|--worker3-ip|--remote-archive|--ssh-user|--ssh-password|--ssh-key-path|--ssh-port)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      SYNC_ARGS+=("$1" "$2")
      shift 2
      ;;
    --skip-containerd-import)
      SYNC_ARGS+=("$1")
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

require_command docker
[[ -x "${SYNC_SCRIPT}" ]] || die "Sync script not executable: ${SYNC_SCRIPT}"

ensure_source_image "${SOURCE_UI_IMAGE}"

docker tag "${SOURCE_UI_IMAGE}" "${TARGET_UI_IMAGE}"

bash "${SYNC_SCRIPT}" \
  --image-ref "${TARGET_UI_IMAGE}" \
  --archive-path /tmp/platform-headlamp-v0.38.0.tar \
  --remote-archive /tmp/platform-headlamp-v0.38.0.tar \
  "${SYNC_ARGS[@]}"

printf '[%s] Synced cluster UI image:\n' "$(basename "$0")"
printf '  %s\n' "${TARGET_UI_IMAGE}"
