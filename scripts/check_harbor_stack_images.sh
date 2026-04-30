#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
NODES_CSV="${NODES_CSV:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
SHOW_PRESENT=0

usage() {
  cat <<'EOF'
Usage: bash scripts/check_harbor_stack_images.sh [options]

Checks whether required stack images exist in node containerd under
harbor.local/data-platform/* tags.

Options:
  --nodes <csv>          Node IPs to check. Example: 192.168.56.10,192.168.56.11,192.168.56.12
                         If omitted, derives InternalIP list from kubectl.
  --ssh-user <user>      SSH user. Default: ubuntu
  --ssh-password <pass>  SSH password. Default: ubuntu
  --ssh-key <path>       SSH private key path (optional)
  --ssh-port <port>      SSH port. Default: 22
  --kubeconfig <path>    KUBECONFIG path for node discovery
  --show-present         Also print PRESENT refs per node
  -h, --help             Show this help
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
  if [[ -n "${KUBECONFIG_PATH}" ]]; then
    KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"
    return
  fi
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

build_ssh_opts() {
  SSH_OPTS=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
    -p "${SSH_PORT}"
  )
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    SSH_OPTS+=(-i "${SSH_KEY_PATH}")
  fi
}

ssh_collect_images() {
  local ip="$1"
  local remote_cmd
  remote_cmd="printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' ctr -n k8s.io images ls -q"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "${remote_cmd}"
    return
  fi

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "sudo ctr -n k8s.io images ls -q"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --kubeconfig)
      [[ $# -ge 2 ]] || die "--kubeconfig requires a value"
      KUBECONFIG_PATH="$2"
      shift 2
      ;;
    --show-present)
      SHOW_PRESENT=1
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
require_command ssh
require_command kubectl
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

build_ssh_opts

if [[ -z "${NODES_CSV}" ]]; then
  NODES_CSV="$(
    run_kubectl get nodes -o wide --no-headers | awk '{print $6}' | paste -sd, -
  )"
fi

[[ -n "${NODES_CSV}" ]] || die "No node IPs to check. Use --nodes or ensure kubectl node list is available."

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

declare -a NODE_FILES=()
for ip in "${NODES[@]}"; do
  ip="${ip// /}"
  [[ -n "${ip}" ]] || continue
  out_file="${TMP_DIR}/images-${ip}.txt"
  ssh_collect_images "${ip}" | sort -u > "${out_file}"
  NODE_FILES+=("${ip}:${out_file}")
done

cat "${TMP_DIR}"/images-*.txt | sort -u > "${TMP_DIR}/union.txt"

overall_missing=0
total_required="${#REQUIRED_IMAGES[@]}"

for pair in "${NODE_FILES[@]}"; do
  ip="${pair%%:*}"
  file="${pair#*:}"
  missing=0
  present=0

  printf '=== %s ===\n' "${ip}"
  for ref in "${REQUIRED_IMAGES[@]}"; do
    if grep -Fxq "${ref}" "${file}"; then
      present=$((present + 1))
      if [[ "${SHOW_PRESENT}" == "1" ]]; then
        printf 'PRESENT %s\n' "${ref}"
      fi
    else
      printf 'MISSING %s\n' "${ref}"
      missing=$((missing + 1))
    fi
  done

  harbor_tagged_total="$(grep -c '^harbor.local/data-platform/' "${file}" || true)"
  printf 'SUMMARY required=%s present=%s missing=%s harbor_tagged_total=%s\n\n' \
    "${total_required}" "${present}" "${missing}" "${harbor_tagged_total}"
done

printf '=== UNION (all nodes) ===\n'
union_missing=0
for ref in "${REQUIRED_IMAGES[@]}"; do
  if ! grep -Fxq "${ref}" "${TMP_DIR}/union.txt"; then
    printf 'MISSING %s\n' "${ref}"
    union_missing=$((union_missing + 1))
  fi
done
union_present=$((total_required - union_missing))
union_harbor_total="$(grep -c '^harbor.local/data-platform/' "${TMP_DIR}/union.txt" || true)"
printf 'UNION_SUMMARY required=%s present=%s missing=%s harbor_tagged_union=%s\n' \
  "${total_required}" "${union_present}" "${union_missing}" "${union_harbor_total}"

if [[ "${union_missing}" -gt 0 ]]; then
  exit 1
fi
