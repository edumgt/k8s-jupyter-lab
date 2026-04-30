#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-data-platform}"
WORKER1_NAME="${WORKER1_NAME:-k8s-worker-1}"
WORKER2_NAME="${WORKER2_NAME:-k8s-worker-2}"
WORKER3_NAME="${WORKER3_NAME:-k8s-worker-3}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"
REMOTE_HOME_REPO_ROOT="${REMOTE_HOME_REPO_ROOT:-/home/Kubernetes-Jupyter-Sandbox}"

SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

SKIP_REPO_COPY=0
SKIP_HARBOR_IMAGE_CHECK=0

NAMESPACE=""
SSH_OPTS=()
SCP_OPTS=()
CONTROL_PLANE_NODE_IP=""
WORKER1_NODE_IP=""
WORKER2_NODE_IP=""
WORKER3_NODE_IP=""

usage() {
  cat <<'EOF'
Usage: bash scripts/vmware_pre_export_prepare.sh [options]

Pre-export safety steps for existing VMware cluster:
  1) Copy current local repository to /home/Kubernetes-Jupyter-Sandbox on each VM
  2) Check Kubernetes pod/service status right before VM stop
  3) Verify namespace pod images are harbor.local/*
  4) Verify required harbor.local/data-platform/* images exist on all nodes

Options:
  --vars-file PATH             Packer vars file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --control-plane-ip IP        Required control-plane SSH host/IP
  --control-plane-name NAME    Default: k8s-data-platform
  --worker1-name NAME          Default: k8s-worker-1
  --worker2-name NAME          Default: k8s-worker-2
  --worker3-name NAME          Optional worker-3 hostname (default: k8s-worker-3)
  --env dev|prod               Default: dev
  --remote-repo-root PATH      Remote runtime repo root (default: /opt/k8s-data-platform)
  --remote-home-repo-root PATH Repo sync target on VM (default: /home/Kubernetes-Jupyter-Sandbox)

  --ssh-user USER              Override SSH user (defaults from vars file ssh_username)
  --ssh-password PASS          Override SSH password (defaults from vars file ssh_password)
  --ssh-key-path PATH          SSH key path (optional)
  --ssh-port PORT              Default: 22

  --skip-repo-copy             Skip repository copy to /home/Kubernetes-Jupyter-Sandbox
  --skip-harbor-image-check    Skip harbor image checks
  -h, --help                   Show this help
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

is_windows_style_path() {
  [[ "$1" =~ ^[A-Za-z]:[\\/].* ]]
}

to_unix_path() {
  local path="$1"
  if is_windows_style_path "${path}"; then
    wslpath -u "${path}"
    return 0
  fi
  printf '%s' "${path}"
}

read_optional_packer_var() {
  local vars_file="$1"
  local key="$2"
  local raw_value

  raw_value="$(
    awk -F '=' -v key="${key}" '
      $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
        sub(/^[^=]*=/, "", $0)
        print $0
        exit
      }
    ' "${vars_file}"
  )"
  raw_value="$(trim "${raw_value}")"
  raw_value="${raw_value#\"}"
  raw_value="${raw_value%\"}"
  printf '%s' "${raw_value}"
}

read_packer_var() {
  local vars_file="$1"
  local key="$2"
  local value
  value="$(read_optional_packer_var "${vars_file}" "${key}")"
  [[ -n "${value}" ]] || die "Required setting not found in ${vars_file}: ${key}"
  printf '%s' "${value}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

build_ssh_opts() {
  SSH_OPTS=(
    -p "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
  )
  SCP_OPTS=(
    -P "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
  )
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    SSH_OPTS+=(-i "${SSH_KEY_PATH}")
    SCP_OPTS+=(-i "${SSH_KEY_PATH}")
  fi
}

ssh_run() {
  local host="$1"
  local command="$2"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "${command}"
    return
  fi

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "${command}"
}

ssh_capture() {
  local host="$1"
  local command="$2"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "${command}"
    return
  fi

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "${command}"
}

build_remote_sudo_bash_cmd() {
  local command="$1"
  local command_escaped
  local password_escaped

  command_escaped="$(printf '%q' "${command}")"
  if [[ -n "${SSH_PASSWORD}" ]]; then
    password_escaped="$(printf '%q' "${SSH_PASSWORD}")"
    printf "printf '%%s\\n' %s | sudo -S -p '' bash -lc %s" "${password_escaped}" "${command_escaped}"
    return 0
  fi

  printf "sudo bash -lc %s" "${command_escaped}"
}

ssh_run_sudo() {
  local host="$1"
  shift
  local command="$*"

  ssh_run "${host}" "$(build_remote_sudo_bash_cmd "${command}")"
}

ssh_capture_sudo() {
  local host="$1"
  shift
  local command="$*"

  ssh_capture "${host}" "$(build_remote_sudo_bash_cmd "${command}")"
}

sync_repo_to_host() {
  local host="$1"
  local label="$2"

  log "Syncing local repo to ${label} (${host}) -> ${REMOTE_HOME_REPO_ROOT}"
  ssh_run_sudo "${host}" "install -d -m 0755 '${REMOTE_HOME_REPO_ROOT}' && chown '${SSH_USER}:${SSH_USER}' '${REMOTE_HOME_REPO_ROOT}'"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    tar \
      --exclude='.git' \
      --exclude='.venv' \
      --exclude='node_modules' \
      --exclude='dist' \
      --exclude='tmp' \
      --exclude='.codex-tmp' \
      -C "${ROOT_DIR}" -cf - . \
      | SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "tar -xf - -C '${REMOTE_HOME_REPO_ROOT}'"
  else
    tar \
      --exclude='.git' \
      --exclude='.venv' \
      --exclude='node_modules' \
      --exclude='dist' \
      --exclude='tmp' \
      --exclude='.codex-tmp' \
      -C "${ROOT_DIR}" -cf - . \
      | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "tar -xf - -C '${REMOTE_HOME_REPO_ROOT}'"
  fi
}

resolve_node_ips() {
  local rows

  rows="$(
    ssh_capture_sudo "${CONTROL_PLANE_IP}" \
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide --no-headers | awk '{print \$1 \",\" \$6}'"
  )"
  [[ -n "${rows}" ]] || die "Unable to list node IPs from control-plane."

  while IFS=',' read -r node_name node_ip; do
    node_name="$(trim "${node_name}")"
    node_ip="$(trim "${node_ip}")"
    [[ -n "${node_name}" && -n "${node_ip}" ]] || continue
    case "${node_name}" in
      "${CONTROL_PLANE_NAME}")
        CONTROL_PLANE_NODE_IP="${node_ip}"
        ;;
      "${WORKER1_NAME}")
        WORKER1_NODE_IP="${node_ip}"
        ;;
      "${WORKER2_NAME}")
        WORKER2_NODE_IP="${node_ip}"
        ;;
      "${WORKER3_NAME}")
        WORKER3_NODE_IP="${node_ip}"
        ;;
    esac
  done <<< "${rows}"

  [[ -n "${CONTROL_PLANE_NODE_IP}" ]] || CONTROL_PLANE_NODE_IP="${CONTROL_PLANE_IP}"
  [[ -n "${WORKER1_NODE_IP}" ]] || die "Unable to resolve ${WORKER1_NAME} IP from kubectl get nodes -o wide."
  [[ -n "${WORKER2_NODE_IP}" ]] || die "Unable to resolve ${WORKER2_NAME} IP from kubectl get nodes -o wide."
  if [[ -z "${WORKER3_NODE_IP}" ]]; then
    log "Worker-3 node '${WORKER3_NAME}' not found in current cluster; continuing without worker-3 pre-export sync/check target."
  fi
}

run_k8s_status_checks() {
  local status_script="${REMOTE_REPO_ROOT}/scripts/status_k8s.sh"

  log "Running pre-stop Kubernetes status check (pods/services)"
  ssh_run_sudo "${CONTROL_PLANE_IP}" "bash '${status_script}' --env '${ENVIRONMENT}'"

  log "Validating pod readiness in namespace ${NAMESPACE}"
  ssh_run_sudo "${CONTROL_PLANE_IP}" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods --no-headers | awk 'NF && \$3 != \"Running\" && \$3 != \"Completed\" { print; bad=1 } END { exit bad }'"

  log "Validating service status in namespace ${NAMESPACE}"
  ssh_run_sudo "${CONTROL_PLANE_IP}" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get svc --no-headers | awk 'NF { count++ } END { if (count == 0) { exit 1 } }'"
  ssh_run_sudo "${CONTROL_PLANE_IP}" \
    "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get svc"
}

run_harbor_image_checks() {
  local images
  local bad=0
  local image
  local nodes_csv
  local local_check_script
  local -a local_cmd=()

  images="$(
    ssh_capture_sudo "${CONTROL_PLANE_IP}" \
      "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{\"\\n\"}{end}{range .spec.containers[*]}{.image}{\"\\n\"}{end}{end}'"
  )"

  [[ -n "${images//[[:space:]]/}" ]] || die "No running pod image entries found in namespace ${NAMESPACE}."

  while IFS= read -r image; do
    image="$(trim "${image}")"
    [[ -n "${image}" ]] || continue
    if [[ ! "${image}" =~ ^harbor\.local/ ]]; then
      printf '[%s] non-harbor image detected: %s\n' "$(basename "$0")" "${image}" >&2
      bad=1
    fi
  done <<< "${images}"

  [[ "${bad}" -eq 0 ]] || die "Detected non-harbor image references in namespace ${NAMESPACE}."

  nodes_csv="${CONTROL_PLANE_NODE_IP},${WORKER1_NODE_IP},${WORKER2_NODE_IP}"
  if [[ -n "${WORKER3_NODE_IP}" ]]; then
    nodes_csv="${nodes_csv},${WORKER3_NODE_IP}"
  fi
  local_check_script="${ROOT_DIR}/scripts/check_harbor_stack_images.sh"
  [[ -f "${local_check_script}" ]] || die "Local harbor check script not found: ${local_check_script}"

  local_cmd=(
    bash "${local_check_script}"
    --nodes "${nodes_csv}"
    --ssh-user "${SSH_USER}"
    --ssh-port "${SSH_PORT}"
  )
  if [[ -n "${SSH_PASSWORD}" ]]; then
    local_cmd+=(--ssh-password "${SSH_PASSWORD}")
  elif [[ -n "${SSH_KEY_PATH}" ]]; then
    local_cmd+=(--ssh-key "${SSH_KEY_PATH}")
  else
    die "Harbor stack image check requires --ssh-password or --ssh-key-path."
  fi

  "${local_cmd[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --control-plane-ip)
      [[ $# -ge 2 ]] || die "--control-plane-ip requires a value"
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --control-plane-name)
      [[ $# -ge 2 ]] || die "--control-plane-name requires a value"
      CONTROL_PLANE_NAME="$2"
      shift 2
      ;;
    --worker1-name)
      [[ $# -ge 2 ]] || die "--worker1-name requires a value"
      WORKER1_NAME="$2"
      shift 2
      ;;
    --worker2-name)
      [[ $# -ge 2 ]] || die "--worker2-name requires a value"
      WORKER2_NAME="$2"
      shift 2
      ;;
    --worker3-name)
      [[ $# -ge 2 ]] || die "--worker3-name requires a value"
      WORKER3_NAME="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --remote-repo-root)
      [[ $# -ge 2 ]] || die "--remote-repo-root requires a value"
      REMOTE_REPO_ROOT="$2"
      shift 2
      ;;
    --remote-home-repo-root)
      [[ $# -ge 2 ]] || die "--remote-home-repo-root requires a value"
      REMOTE_HOME_REPO_ROOT="$2"
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
    --skip-repo-copy)
      SKIP_REPO_COPY=1
      shift
      ;;
    --skip-harbor-image-check)
      SKIP_HARBOR_IMAGE_CHECK=1
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

if is_windows_style_path "${PACKER_VARS}"; then
  PACKER_VARS="$(to_unix_path "${PACKER_VARS}")"
fi
if is_windows_style_path "${SSH_KEY_PATH:-}"; then
  SSH_KEY_PATH="$(to_unix_path "${SSH_KEY_PATH}")"
fi

[[ -f "${PACKER_VARS}" ]] || die "Packer vars file not found: ${PACKER_VARS}"
[[ -n "${CONTROL_PLANE_IP}" ]] || die "--control-plane-ip is required"

if [[ -z "${SSH_USER}" ]]; then
  SSH_USER="$(read_packer_var "${PACKER_VARS}" ssh_username)"
fi
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_KEY_PATH}" ]]; then
  SSH_PASSWORD="$(read_optional_packer_var "${PACKER_VARS}" ssh_password)"
fi

[[ -n "${SSH_USER}" ]] || die "Unable to resolve SSH user."
[[ -n "${SSH_PASSWORD}" || -n "${SSH_KEY_PATH}" ]] || die "Provide --ssh-password or --ssh-key-path."
if [[ -n "${SSH_KEY_PATH}" ]]; then
  [[ -f "${SSH_KEY_PATH}" ]] || die "SSH key path not found: ${SSH_KEY_PATH}"
fi

case "${ENVIRONMENT}" in
  dev|prod) ;;
  *) die "Unsupported --env: ${ENVIRONMENT}. Use dev or prod." ;;
esac
NAMESPACE="data-platform-${ENVIRONMENT}"

require_command bash
require_command awk
require_command tar
require_command ssh
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

build_ssh_opts
resolve_node_ips

if [[ "${SKIP_REPO_COPY}" -eq 0 ]]; then
  sync_repo_to_host "${CONTROL_PLANE_NODE_IP}" "control-plane"
  sync_repo_to_host "${WORKER1_NODE_IP}" "worker-1"
  sync_repo_to_host "${WORKER2_NODE_IP}" "worker-2"
  if [[ -n "${WORKER3_NODE_IP}" ]]; then
    sync_repo_to_host "${WORKER3_NODE_IP}" "worker-3"
  fi
else
  log "Skipping repository copy (--skip-repo-copy)"
fi

run_k8s_status_checks

if [[ "${SKIP_HARBOR_IMAGE_CHECK}" -eq 0 ]]; then
  log "Running harbor image checks (namespace image refs + node image cache)"
  run_harbor_image_checks
else
  log "Skipping harbor image checks (--skip-harbor-image-check)"
fi

log "Pre-export preparation completed."
