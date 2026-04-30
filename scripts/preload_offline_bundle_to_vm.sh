#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${ROOT_DIR}/scripts/lib/image_registry.sh"
PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.vmware.auto.pkrvars.hcl}"
BUNDLE_DIR="${BUNDLE_DIR:-${ROOT_DIR}/dist/offline-bundle}"
REMOTE_BUNDLE_DIR="${REMOTE_BUNDLE_DIR:-/opt/k8s-data-platform/offline-bundle}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-harbor.local}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-data-platform}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
SKIP_BUILD=0
APPLY_MANIFESTS=0
WITH_RUNNER=0
required_images=()
missing_required_images=()

usage() {
  cat <<'EOF'
Usage: bash scripts/preload_offline_bundle_to_vm.sh [options]

Builds or reuses the offline bundle on the local machine, copies it to the
target VM, then imports image archives into Docker/containerd on the VM.

Options:
  --control-plane-ip IP       Target VM IP (required unless env is set).
  --vars-file PATH            Packer vars file for default SSH credentials.
  --bundle-dir PATH           Local offline bundle directory.
  --remote-bundle-dir PATH    Remote bundle directory on the VM.
  --ssh-user USER             SSH username override.
  --ssh-password PASS         SSH password override.
  --ssh-key-path PATH         SSH private key override.
  --ssh-port PORT             SSH port override (default: 22).
  --env dev|prod              Overlay env for optional --apply.
  --registry HOST             Image registry for bundle build/apply (default: harbor.local).
  --namespace NAME            Image namespace for bundle build (default: data-platform).
  --tag TAG                   App image tag for bundle build (default: latest).
  --skip-build                Reuse an existing local offline bundle.
  --apply                     Apply bundled manifests after import.
  --with-runner               Apply runner overlay too (requires --apply).
  -h, --help                  Show this help.
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

trim() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

read_optional_packer_var() {
  local key="$1"
  local raw_value

  raw_value="$(
    awk -F '=' -v key="${key}" '
      $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
        sub(/^[^=]*=/, "", $0)
        print $0
        exit
      }
    ' "${PACKER_VARS}"
  )"
  raw_value="$(trim "${raw_value}")"
  raw_value="${raw_value#\"}"
  raw_value="${raw_value%\"}"
  printf '%s' "${raw_value}"
}

ssh_opts=()
scp_opts=()

build_ssh_opts() {
  ssh_opts=(
    -p "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
  )
  scp_opts=(
    -P "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
  )

  if [[ -n "${SSH_KEY_PATH}" ]]; then
    ssh_opts+=(-i "${SSH_KEY_PATH}")
    scp_opts+=(-i "${SSH_KEY_PATH}")
  fi
}

ssh_run() {
  local host="$1"
  shift

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
    return
  fi

  ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
}

scp_copy_dir() {
  local src="$1"
  local host="$2"
  local dst="$3"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${scp_opts[@]}" -r "${src}" "${SSH_USER}@${host}:${dst}"
    return
  fi

  scp "${scp_opts[@]}" -r "${src}" "${SSH_USER}@${host}:${dst}"
}

remote_sudo() {
  local host="$1"
  local command="$2"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    ssh_run "${host}" "printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' bash -lc $(printf '%q' "${command}")"
    return
  fi

  ssh_run "${host}" "sudo bash -lc $(printf '%q' "${command}")"
}

resolve_remote_import_script() {
  local host="$1"
  local candidate
  local candidates=(
    "${REMOTE_BUNDLE_DIR}/k8s/scripts/import_offline_bundle.sh"
    "/opt/k8s-data-platform/scripts/import_offline_bundle.sh"
  )

  for candidate in "${candidates[@]}"; do
    if ssh_run "${host}" "test -f '${candidate}' && bash '${candidate}' --help >/dev/null 2>&1"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  return 1
}

remote_import_supports_registry_overrides() {
  local host="$1"
  local script_path="$2"
  local help_output

  help_output="$(ssh_run "${host}" "bash '${script_path}' --help 2>&1" || true)"

  grep -Fq -- "--image-registry" <<< "${help_output}" \
    && grep -Fq -- "--image-namespace" <<< "${help_output}" \
    && grep -Fq -- "--image-tag" <<< "${help_output}"
}

sanitize_archive_name() {
  printf '%s' "$1" | tr '/:' '-'
}

initialize_required_images() {
  required_images=(
    "$(platform_support_image platform-python 3.12-slim)"
    "$(platform_support_image platform-python 3.12)"
    "$(platform_support_image platform-node 22.22.0-bookworm-slim)"
    "$(platform_support_image platform-nginx 1.27-alpine)"
    "$(platform_support_image platform-airflow-base 2.10.5-python3.12)"
    "$(platform_support_image platform-mongodb 7.0)"
    "$(platform_support_image platform-redis 7-alpine)"
    "$(platform_support_image platform-gitlab-ce 17.10.0-ce.0)"
    "$(platform_support_image platform-gitlab-runner alpine-v17.10.0)"
    "$(platform_support_image platform-gitlab-runner-helper x86_64-v17.10.0)"
    "$(platform_support_image platform-nexus3 3.90.1-alpine)"
    "$(platform_support_image platform-kaniko-executor v1.23.2-debug)"
    "$(platform_support_image platform-kubectl latest)"
    "$(platform_support_image platform-bash 5.2)"
    "$(platform_support_image platform-alpine 3.20)"
    "$(platform_support_image platform-busybox 1.36)"
    "$(platform_support_image platform-calico-cni v3.31.2)"
    "$(platform_support_image platform-calico-node v3.31.2)"
    "$(platform_support_image platform-calico-kube-controllers v3.31.2)"
    "$(platform_support_image platform-metallb-controller v0.15.3)"
    "$(platform_support_image platform-metallb-speaker v0.15.3)"
    "$(platform_support_image platform-ingress-nginx-controller v1.14.1)"
    "$(platform_support_image platform-ingress-nginx-kube-webhook-certgen v1.6.5)"
    "$(platform_support_image platform-headlamp v0.38.0)"
    "$(platform_app_image backend)"
    "$(platform_app_image frontend)"
    "$(platform_app_image airflow)"
    "$(platform_app_image jupyter)"
  )
}

collect_missing_required_images() {
  local host="$1"
  local images_on_host
  local ref

  missing_required_images=()
  images_on_host="$(remote_sudo "${host}" "ctr -n k8s.io images ls -q | sort -u")"
  for ref in "${required_images[@]}"; do
    if ! grep -Fqx "${ref}" <<< "${images_on_host}"; then
      missing_required_images+=("${ref}")
    fi
  done
}

recover_missing_required_images() {
  local host="$1"
  local ref archive_name remote_archive

  if [[ "${#missing_required_images[@]}" -eq 0 ]]; then
    return 0
  fi

  log "Attempting targeted recovery for ${#missing_required_images[@]} missing image(s)."
  for ref in "${missing_required_images[@]}"; do
    archive_name="$(sanitize_archive_name "${ref}").tar"
    remote_archive="${REMOTE_BUNDLE_DIR}/images/${archive_name}"

    log "Recovering missing image: ${ref}"
    remote_sudo "${host}" "test -f '${remote_archive}'" \
      || die "Missing archive for ${ref}: ${remote_archive}"

    if ! remote_sudo "${host}" "ctr -n k8s.io images import --platform linux/amd64 '${remote_archive}'"; then
      log "Primary recovery import failed for ${ref}; retrying with --all-platforms."
      remote_sudo "${host}" "ctr -n k8s.io images import --all-platforms '${remote_archive}'" \
        || die "Unable to recover image ${ref}"
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --control-plane-ip)
      [[ $# -ge 2 ]] || die "--control-plane-ip requires a value"
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --remote-bundle-dir)
      [[ $# -ge 2 ]] || die "--remote-bundle-dir requires a value"
      REMOTE_BUNDLE_DIR="$2"
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
    --ssh-key-path)
      [[ $# -ge 2 ]] || die "--ssh-key-path requires a value"
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port requires a value"
      SSH_PORT="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --registry)
      [[ $# -ge 2 ]] || die "--registry requires a value"
      IMAGE_REGISTRY="$2"
      shift 2
      ;;
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      IMAGE_NAMESPACE="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --apply)
      APPLY_MANIFESTS=1
      shift
      ;;
    --with-runner)
      WITH_RUNNER=1
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

[[ -f "${PACKER_VARS}" ]] || die "Packer vars file not found: ${PACKER_VARS}"
[[ -n "${CONTROL_PLANE_IP}" ]] || die "--control-plane-ip is required"
if [[ -z "${SSH_USER}" ]]; then
  SSH_USER="$(read_optional_packer_var ssh_username)"
fi
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_KEY_PATH}" ]]; then
  SSH_PASSWORD="$(read_optional_packer_var ssh_password)"
fi
[[ -n "${SSH_USER}" ]] || die "Unable to determine SSH user."
[[ -n "${SSH_PASSWORD}" || -n "${SSH_KEY_PATH}" ]] || die "Provide --ssh-password or --ssh-key-path."
[[ "${WITH_RUNNER}" != "1" || "${APPLY_MANIFESTS}" == "1" ]] || die "--with-runner requires --apply"

require_command bash
require_command scp
require_command ssh
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

initialize_required_images
build_ssh_opts

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  log "Building offline bundle locally: ${BUNDLE_DIR}"
  IMAGE_REGISTRY="${IMAGE_REGISTRY}" IMAGE_NAMESPACE="${IMAGE_NAMESPACE}" IMAGE_TAG="${IMAGE_TAG}" \
    bash "${ROOT_DIR}/scripts/prepare_offline_bundle.sh" --out-dir "${BUNDLE_DIR}" --registry "${IMAGE_REGISTRY}" --namespace "${IMAGE_NAMESPACE}" --tag "${IMAGE_TAG}"
else
  log "Reusing existing offline bundle: ${BUNDLE_DIR}"
fi

[[ -d "${BUNDLE_DIR}/images" ]] || die "Offline bundle images directory missing: ${BUNDLE_DIR}/images"
[[ -d "${BUNDLE_DIR}/k8s" ]] || die "Offline bundle k8s directory missing: ${BUNDLE_DIR}/k8s"

log "Preparing remote bundle directory: ${REMOTE_BUNDLE_DIR}"
remote_sudo "${CONTROL_PLANE_IP}" "rm -rf '${REMOTE_BUNDLE_DIR}' && mkdir -p '${REMOTE_BUNDLE_DIR}' && chown '${SSH_USER}:${SSH_USER}' '${REMOTE_BUNDLE_DIR}'"

log "Copying offline bundle to ${CONTROL_PLANE_IP}"
scp_copy_dir "${BUNDLE_DIR}/." "${CONTROL_PLANE_IP}" "${REMOTE_BUNDLE_DIR}/"

log "Importing image archives on target VM"
import_script_path="$(
  resolve_remote_import_script "${CONTROL_PLANE_IP}"
)" || die "Unable to locate import_offline_bundle.sh on target VM."
log "Using remote import script: ${import_script_path}"

import_cmd="bash '${import_script_path}' --bundle-dir '${REMOTE_BUNDLE_DIR}' --env '${ENVIRONMENT}'"
if remote_import_supports_registry_overrides "${CONTROL_PLANE_IP}" "${import_script_path}"; then
  import_cmd="${import_cmd} --image-registry '${IMAGE_REGISTRY}' --image-namespace '${IMAGE_NAMESPACE}' --image-tag '${IMAGE_TAG}'"
else
  log "Remote import script does not support registry override options; proceeding without overrides."
fi
if [[ "${APPLY_MANIFESTS}" == "1" ]]; then
  import_cmd="${import_cmd} --apply"
fi
if [[ "${WITH_RUNNER}" == "1" ]]; then
  import_cmd="${import_cmd} --with-runner"
fi

remote_sudo "${CONTROL_PLANE_IP}" "command -v ctr >/dev/null 2>&1" \
  || die "ctr command not available on target VM."

primary_import_failed=0
if ! remote_sudo "${CONTROL_PLANE_IP}" "${import_cmd}"; then
  primary_import_failed=1
  log "Primary import command failed; continuing with targeted recovery."
fi

max_recovery_rounds=4
recovery_round=0
while true; do
  collect_missing_required_images "${CONTROL_PLANE_IP}"
  if [[ "${#missing_required_images[@]}" -eq 0 ]]; then
    break
  fi

  if [[ "${recovery_round}" -ge "${max_recovery_rounds}" ]]; then
    die "Missing required images remain after recovery: $(IFS=,; printf '%s' "${missing_required_images[*]}")"
  fi

  recovery_round=$((recovery_round + 1))
  log "Detected ${#missing_required_images[@]} missing required image(s) (recovery round ${recovery_round}/${max_recovery_rounds})."
  recover_missing_required_images "${CONTROL_PLANE_IP}"
done

if [[ "${primary_import_failed}" -eq 1 ]]; then
  log "Primary import reported an error, but targeted recovery completed successfully."
fi

log "Offline bundle preload completed."
log "Target VM: ${CONTROL_PLANE_IP}"
log "Remote bundle path: ${REMOTE_BUNDLE_DIR}"
