#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-ubuntu}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"
MODE="${MODE:-status}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

usage() {
  cat <<'USAGE'
Usage: bash scripts/sync_repo_runtime_with_vm.sh [options]

Compares runtime-relevant repo files with the control-plane VM copy and can
sync the newer local version into the VM after export/import work is finished.

Options:
  --control-plane-ip <ip>   Required control-plane VM IP.
  --ssh-user <user>         SSH username. Defaults to ubuntu.
  --ssh-password <pass>     SSH password. Defaults to ubuntu.
  --remote-repo-root <dir>  Remote repo root. Defaults to /opt/k8s-data-platform.
  --mode <status|push>      status: compare only, push: copy local files to VM.
  -h, --help                Show this help.
USAGE
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ssh_cmd() {
  SSHPASS="${SSH_PASSWORD}" sshpass -e ssh \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@${CONTROL_PLANE_IP}" "$@"
}

scp_cmd() {
  SSHPASS="${SSH_PASSWORD}" sshpass -e scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$@"
}

runtime_file_list() {
  cat <<'EOF_LIST'
apps/backend/app/main.py
infra/k8s/base/airflow.yaml
infra/k8s/base/backend.yaml
infra/k8s/base/gitlab.yaml
infra/k8s/base/platform-configmap.yaml
infra/k8s/overlays/dev/platform-configmap-patch.yaml
ovabuild.sh
scripts/apply_k8s.sh
scripts/build_k8s_images.sh
scripts/check_offline_readiness.sh
scripts/check_vm_airgap_status.sh
scripts/import_offline_bundle.sh
scripts/install_vm_airgap_postboot_timer.sh
scripts/install_vm_base_packages.sh
scripts/preload_offline_bundle_to_vm.sh
scripts/prepare_offline_bundle.sh
scripts/setup_ingress_metallb.sh
scripts/verify.sh
scripts/install_vm_apt_bundle_to_vms.sh
scripts/lib/image_registry.sh
scripts/lib/vm_base_packages.sh
scripts/prepare_vm_apt_bundle.sh
scripts/sync_docker_image_to_vms.sh
EOF_LIST
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-plane-ip)
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-password)
      SSH_PASSWORD="$2"
      shift 2
      ;;
    --remote-repo-root)
      REMOTE_REPO_ROOT="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
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

[[ -n "${CONTROL_PLANE_IP}" ]] || die "--control-plane-ip is required"
[[ "${MODE}" == "status" || "${MODE}" == "push" ]] || die "--mode must be status or push"

mapfile -t FILES < <(runtime_file_list)

printf '[sync_repo_runtime_with_vm.sh] mode=%s remote=%s@%s:%s\n' "${MODE}" "${SSH_USER}" "${CONTROL_PLANE_IP}" "${REMOTE_REPO_ROOT}"

for rel in "${FILES[@]}"; do
  local_path="${ROOT_DIR}/${rel}"
  remote_path="${REMOTE_REPO_ROOT}/${rel}"

  if [[ ! -f "${local_path}" ]]; then
    printf '[missing-local] %s\n' "${rel}"
    continue
  fi

  local_sum="$(sha256sum "${local_path}" | awk '{print $1}')"
  remote_sum="$(
    ssh_cmd "if [ -f '${remote_path}' ]; then sha256sum '${remote_path}' | awk '{print \$1}'; fi" 2>/dev/null || true
  )"

  if [[ -z "${remote_sum}" ]]; then
    printf '[missing-remote] %s\n' "${rel}"
    if [[ "${MODE}" == "push" ]]; then
      ssh_cmd "mkdir -p '$(dirname "${remote_path}")'"
      scp_cmd "${local_path}" "${SSH_USER}@${CONTROL_PLANE_IP}:${remote_path}"
      printf '[pushed] %s\n' "${rel}"
    fi
    continue
  fi

  if [[ "${local_sum}" == "${remote_sum}" ]]; then
    printf '[same] %s\n' "${rel}"
    continue
  fi

  printf '[diff] %s\n' "${rel}"
  if [[ "${MODE}" == "push" ]]; then
    scp_cmd "${local_path}" "${SSH_USER}@${CONTROL_PLANE_IP}:${remote_path}"
    printf '[pushed] %s\n' "${rel}"
  fi
done
