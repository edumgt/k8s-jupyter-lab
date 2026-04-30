#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.vmware.auto.pkrvars.hcl}"
IMAGE_REF="${IMAGE_REF:-mcr.microsoft.com/playwright:v1.58.2-jammy}"
ARCHIVE_PATH="${ARCHIVE_PATH:-/tmp/playwright-image.tar}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.56.10}"
WORKER1_IP="${WORKER1_IP:-192.168.56.11}"
WORKER2_IP="${WORKER2_IP:-192.168.56.12}"
WORKER3_IP="${WORKER3_IP:-}"
REMOTE_ARCHIVE_PATH="${REMOTE_ARCHIVE_PATH:-/tmp/docker-image-sync.tar}"
SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
IMPORT_CONTAINERD=1

usage() {
  cat <<'EOF'
Usage: bash scripts/sync_docker_image_to_vms.sh [options]

Saves a Docker image from the local Docker engine and loads it into Docker on
the three VMware nodes over SSH/SCP.

Options:
  --image-ref IMAGE          Docker image reference to sync.
  --archive-path PATH        Local image tar path.
  --remote-archive PATH      Remote temp archive path.
  --vars-file PATH           Packer vars file for SSH defaults.
  --control-plane-ip IP      Control-plane VM IP.
  --worker1-ip IP            Worker 1 VM IP.
  --worker2-ip IP            Worker 2 VM IP.
  --worker3-ip IP            Optional worker 3 VM IP.
  --ssh-user USER            SSH username override.
  --ssh-password PASS        SSH password override.
  --ssh-key-path PATH        SSH private key override.
  --ssh-port PORT            SSH port override.
  --skip-containerd-import   Load only into Docker, not containerd.
  -h, --help                 Show this help.
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ssh_opts=()
scp_opts=()

build_ssh_opts() {
  ssh_opts=(
    -p "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
  )
  scp_opts=(
    -P "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
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

scp_copy() {
  local src="$1"
  local host="$2"
  local dst="$3"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${scp_opts[@]}" "${src}" "${SSH_USER}@${host}:${dst}"
    return
  fi

  scp "${scp_opts[@]}" "${src}" "${SSH_USER}@${host}:${dst}"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-ref)
      IMAGE_REF="$2"
      shift 2
      ;;
    --archive-path)
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --remote-archive)
      REMOTE_ARCHIVE_PATH="$2"
      shift 2
      ;;
    --vars-file)
      PACKER_VARS="$2"
      shift 2
      ;;
    --control-plane-ip)
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --worker1-ip)
      WORKER1_IP="$2"
      shift 2
      ;;
    --worker2-ip)
      WORKER2_IP="$2"
      shift 2
      ;;
    --worker3-ip)
      WORKER3_IP="$2"
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
    --ssh-key-path)
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="$2"
      shift 2
      ;;
    --skip-containerd-import)
      IMPORT_CONTAINERD=0
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
if [[ -z "${SSH_USER}" ]]; then
  SSH_USER="$(read_optional_packer_var ssh_username)"
fi
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_KEY_PATH}" ]]; then
  SSH_PASSWORD="$(read_optional_packer_var ssh_password)"
fi
if [[ -z "${WORKER3_IP}" ]]; then
  WORKER3_IP="$(read_optional_packer_var worker3_ip)"
fi

[[ -n "${SSH_USER}" ]] || die "Unable to determine SSH user."
[[ -n "${SSH_PASSWORD}" || -n "${SSH_KEY_PATH}" ]] || die "Provide --ssh-password or --ssh-key-path."

require_command docker
require_command ssh
require_command scp
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

build_ssh_opts

log "Saving local Docker image: ${IMAGE_REF}"
docker image inspect "${IMAGE_REF}" >/dev/null
docker save -o "${ARCHIVE_PATH}" "${IMAGE_REF}"

hosts=(
  "${CONTROL_PLANE_IP}:control-plane"
  "${WORKER1_IP}:worker-1"
  "${WORKER2_IP}:worker-2"
)

if [[ -n "${WORKER3_IP}" ]]; then
  hosts+=("${WORKER3_IP}:worker-3")
fi

for item in "${hosts[@]}"; do
  IFS=':' read -r host label <<<"${item}"
  log "Copying ${IMAGE_REF} archive to ${label} (${host})"
  scp_copy "${ARCHIVE_PATH}" "${host}" "${REMOTE_ARCHIVE_PATH}"
  log "Loading ${IMAGE_REF} into Docker on ${label} (${host})"
  if [[ "${IMPORT_CONTAINERD}" == "1" ]]; then
    remote_sudo "${host}" "
      set -euo pipefail
      remote_archive='${REMOTE_ARCHIVE_PATH}'
      ctr_archive='${REMOTE_ARCHIVE_PATH}.ctr.tar'
      stripped_ref='${IMAGE_REF#docker.io/}'
      docker load -i '${REMOTE_ARCHIVE_PATH}'
      if ! docker image inspect '${IMAGE_REF}' >/dev/null 2>&1; then
        docker image inspect \"\${stripped_ref}\" >/dev/null 2>&1
        docker tag \"\${stripped_ref}\" '${IMAGE_REF}'
      fi
      docker save -o \"\${ctr_archive}\" '${IMAGE_REF}'
      ctr -n k8s.io images import \"\${ctr_archive}\"
      crictl --runtime-endpoint unix:///run/containerd/containerd.sock images | grep -F '${IMAGE_REF%%:*}' >/dev/null || true
      rm -f \"\${remote_archive}\" \"\${ctr_archive}\"
    "
  else
    remote_sudo "${host}" "docker load -i '${REMOTE_ARCHIVE_PATH}' && rm -f '${REMOTE_ARCHIVE_PATH}'"
  fi
done

log "Docker image sync completed for ${IMAGE_REF}"
