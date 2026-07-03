#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.vmware.auto.pkrvars.hcl}"
BUNDLE_DIR="${BUNDLE_DIR:-${ROOT_DIR}/dist/vm-apt-bundle}"
REMOTE_BUNDLE_DIR="${REMOTE_BUNDLE_DIR:-/opt/k8s-data-platform/vm-apt-bundle}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-<YOUR_MASTER_IP>}"
WORKER1_IP="${WORKER1_IP:-<YOUR_WORKER1_IP>}"
WORKER2_IP="${WORKER2_IP:-<YOUR_WORKER2_IP>}"
WORKER3_IP="${WORKER3_IP:-}"
SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

usage() {
  cat <<'EOF'
Usage: bash scripts/install_vm_apt_bundle_to_vms.sh [options]

Copies a prebuilt offline apt bundle from WSL into VMware VMs and installs
the packages without requiring outbound internet access from the VMs.

Options:
  --bundle-dir PATH         Local bundle directory.
  --remote-bundle-dir PATH  Remote bundle directory.
  --vars-file PATH          Packer vars file for SSH defaults.
  --control-plane-ip IP     Control-plane VM IP.
  --worker1-ip IP           Worker 1 VM IP.
  --worker2-ip IP           Worker 2 VM IP.
  --worker3-ip IP           Optional Worker 3 VM IP.
  --ssh-user USER           SSH username override.
  --ssh-password PASS       SSH password override.
  --ssh-key-path PATH       SSH private key override.
  --ssh-port PORT           SSH port override.
  -h, --help                Show this help.
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --remote-bundle-dir)
      REMOTE_BUNDLE_DIR="$2"
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
[[ -d "${BUNDLE_DIR}/deb" ]] || die "Bundle directory missing deb payloads: ${BUNDLE_DIR}/deb"
[[ -f "${BUNDLE_DIR}/install.sh" ]] || die "Bundle installer not found: ${BUNDLE_DIR}/install.sh"

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

require_command ssh
require_command scp
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

build_ssh_opts

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
  log "Copying offline apt bundle to ${label} (${host})"
  remote_sudo "${host}" "rm -rf '${REMOTE_BUNDLE_DIR}' && mkdir -p '${REMOTE_BUNDLE_DIR}' && chown '${SSH_USER}:${SSH_USER}' '${REMOTE_BUNDLE_DIR}'"
  scp_copy_dir "${BUNDLE_DIR}/." "${host}" "${REMOTE_BUNDLE_DIR}"
  log "Installing offline apt bundle on ${label} (${host})"
  remote_sudo "${host}" "bash '${REMOTE_BUNDLE_DIR}/install.sh'"
done

log "Offline apt bundle installation completed."
