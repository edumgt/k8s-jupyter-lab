#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"

BUNDLE_DIR="${BUNDLE_DIR:-${SCRIPT_DIR%/scripts}/dist/offline-bundle}"
NODES_CSV="${NODES_CSV:-}"
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
REMOTE_STAGING_DIR="${REMOTE_STAGING_DIR:-/tmp/harbor-fill}"
SHOW_PRESENT=0
IMPORT_PLATFORM="${IMPORT_PLATFORM:-linux/amd64}"
IMPORT_ALL_PLATFORMS=0

usage() {
  cat <<'EOF'
Usage: bash scripts/fill_missing_harbor_images_from_bundle.sh [options]

Fills missing harbor.local/data-platform/* images on each node containerd
from offline bundle tar archives.

Options:
  --bundle-dir <path>      Offline bundle root path. Default: dist/offline-bundle
  --nodes <csv>            Node IP list. Example: 192.168.56.10,192.168.56.11,192.168.56.12
                           If omitted, discovers node IPs via kubectl.
  --ssh-user <user>        SSH user. Default: ubuntu
  --ssh-password <pass>    SSH password. Default: ubuntu
  --ssh-key <path>         SSH private key path
  --ssh-port <port>        SSH port. Default: 22
  --remote-staging-dir P   Temp dir on remote node. Default: /tmp/harbor-fill
  --import-platform <p>    ctr import platform (default: linux/amd64)
  --all-platforms          ctr import with --all-platforms
  --show-present           Print present refs as well
  -h, --help               Show this help
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
  if [[ -n "${KUBECONFIG:-}" ]]; then
    kubectl "$@"
    return
  fi
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
    return
  fi
  kubectl "$@"
}

sanitize_archive_name() {
  printf '%s' "$1" | tr '/:' '-'
}

build_ssh_opts() {
  SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
    -p "${SSH_PORT}"
  )
  SCP_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
    -P "${SSH_PORT}"
  )
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    SSH_OPTS+=(-i "${SSH_KEY_PATH}")
    SCP_OPTS+=(-i "${SSH_KEY_PATH}")
  fi
}

ssh_run() {
  local ip="$1"
  shift
  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"
    return
  fi
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"
}

scp_copy() {
  local src="$1"
  local ip="$2"
  local dst="$3"
  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${SCP_OPTS[@]}" "${src}" "${SSH_USER}@${ip}:${dst}"
    return
  fi
  scp "${SCP_OPTS[@]}" "${src}" "${SSH_USER}@${ip}:${dst}"
}

remote_sudo() {
  local ip="$1"
  shift
  local command="$*"
  if [[ -n "${SSH_PASSWORD}" ]]; then
    ssh_run "${ip}" "printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' bash -lc $(printf '%q' "${command}")"
    return
  fi
  ssh_run "${ip}" "sudo bash -lc $(printf '%q' "${command}")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      BUNDLE_DIR="$2"
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
    --show-present)
      SHOW_PRESENT=1
      shift
      ;;
    --import-platform)
      [[ $# -ge 2 ]] || die "--import-platform requires a value"
      IMPORT_PLATFORM="$2"
      shift 2
      ;;
    --all-platforms)
      IMPORT_ALL_PLATFORMS=1
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

require_command bash
require_command kubectl
require_command ssh
require_command scp
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

[[ -d "${BUNDLE_DIR}/images" ]] || die "Bundle images dir not found: ${BUNDLE_DIR}/images"
build_ssh_opts

if [[ -z "${NODES_CSV}" ]]; then
  NODES_CSV="$(run_kubectl get nodes -o wide --no-headers | awk '{print $6}' | paste -sd, -)"
fi
[[ -n "${NODES_CSV}" ]] || die "No nodes discovered. Pass --nodes explicitly."
IFS=',' read -r -a NODES <<< "${NODES_CSV}"

REQUIRED_IMAGES=(
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

for ref in "${REQUIRED_IMAGES[@]}"; do
  archive_name="$(sanitize_archive_name "${ref}").tar"
  archive_path="${BUNDLE_DIR}/images/${archive_name}"
  [[ -f "${archive_path}" ]] || die "Missing bundle archive for ${ref}: ${archive_path}"
done

TOTAL_REQUIRED="${#REQUIRED_IMAGES[@]}"

for node_ip in "${NODES[@]}"; do
  node_ip="${node_ip// /}"
  [[ -n "${node_ip}" ]] || continue

  printf '=== %s ===\n' "${node_ip}"

  remote_sudo "${node_ip}" "mkdir -p '${REMOTE_STAGING_DIR}' && chown '${SSH_USER}:${SSH_USER}' '${REMOTE_STAGING_DIR}' && find '${REMOTE_STAGING_DIR}' -maxdepth 1 -type f -name '*.tar' -delete"
  node_images="$(remote_sudo "${node_ip}" "ctr -n k8s.io images ls -q | sort -u")"

  missing_refs=()
  for ref in "${REQUIRED_IMAGES[@]}"; do
    if grep -Fxq "${ref}" <<< "${node_images}"; then
      if [[ "${SHOW_PRESENT}" == "1" ]]; then
        printf 'PRESENT %s\n' "${ref}"
      fi
    else
      missing_refs+=("${ref}")
      printf 'MISSING %s\n' "${ref}"
    fi
  done

  if [[ "${#missing_refs[@]}" -eq 0 ]]; then
    printf 'SUMMARY required=%s present=%s missing=0\n\n' "${TOTAL_REQUIRED}" "${TOTAL_REQUIRED}"
    continue
  fi

  for ref in "${missing_refs[@]}"; do
    archive_name="$(sanitize_archive_name "${ref}").tar"
    local_archive="${BUNDLE_DIR}/images/${archive_name}"
    remote_archive="${REMOTE_STAGING_DIR}/${archive_name}"

    scp_copy "${local_archive}" "${node_ip}" "${remote_archive}"
    if [[ "${IMPORT_ALL_PLATFORMS}" == "1" ]]; then
      import_cmd="ctr -n k8s.io images import --all-platforms '${remote_archive}'"
    else
      import_cmd="ctr -n k8s.io images import --platform '${IMPORT_PLATFORM}' '${remote_archive}'"
    fi
    if ! remote_sudo "${node_ip}" "${import_cmd}"; then
      printf 'IMPORT_FAILED %s\n' "${ref}" >&2
    fi
    remote_sudo "${node_ip}" "rm -f '${remote_archive}'"
  done

  node_images_after="$(remote_sudo "${node_ip}" "ctr -n k8s.io images ls -q | sort -u")"
  missing_after=0
  for ref in "${REQUIRED_IMAGES[@]}"; do
    if ! grep -Fxq "${ref}" <<< "${node_images_after}"; then
      printf 'STILL_MISSING %s\n' "${ref}"
      missing_after=$((missing_after + 1))
    fi
  done

  present_after=$((TOTAL_REQUIRED - missing_after))
  printf 'SUMMARY required=%s present=%s missing=%s\n\n' "${TOTAL_REQUIRED}" "${present_after}" "${missing_after}"
done
