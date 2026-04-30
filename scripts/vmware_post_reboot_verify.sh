#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-data-platform}"
WORKER1_NAME="${WORKER1_NAME:-k8s-worker-1}"
WORKER2_NAME="${WORKER2_NAME:-k8s-worker-2}"
WORKER3_NAME="${WORKER3_NAME:-k8s-worker-3}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"

POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
VMRUN_WIN="${VMRUN_WIN:-C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe}"
WAIT_VM_IP_TIMEOUT_SEC="${WAIT_VM_IP_TIMEOUT_SEC:-600}"

SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

SKIP_GITLAB_CLONE_CHECK=0
STRICT_HARBOR_CHECK=0
GITLAB_INTERNAL_URL="${GITLAB_INTERNAL_URL:-http://127.0.0.1:30089}"

NAMESPACE=""
CONTROL_PLANE_SSH_HOST=""
OUTPUT_DIR_WSL=""
CONTROL_PLANE_VMX_WIN=""
RESOLVED_INGRESS_LB_IP=""
SSH_OPTS=()

log() {
  printf '[vmware_post_reboot_verify.sh] %s\n' "$*"
}

die() {
  printf '[vmware_post_reboot_verify.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/vmware_post_reboot_verify.sh [options]

Post-reboot verification for existing VMware cluster:
  - Resolve control-plane SSH endpoint
  - Wait nodes/pods/PVC readiness
  - Re-run ingress URL checks (verify.sh)
  - Verify GitLab backend/frontend clone access (optional)

Options:
  --vars-file PATH             Packer vars file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --control-plane-name NAME    Default: k8s-data-platform
  --worker1-name NAME          Default: k8s-worker-1
  --worker2-name NAME          Default: k8s-worker-2
  --worker3-name NAME          Default: k8s-worker-3

  --control-plane-ip IP        Use static SSH host directly (skip vmrun IP detect)
  --ingress-lb-ip IP           Fixed ingress LB IP for verify.sh (optional)

  --env dev|prod               Default: dev
  --remote-repo-root PATH      Default: /opt/k8s-data-platform

  --ssh-user USER              Override SSH user (defaults from vars file ssh_username)
  --ssh-password PASS          Override SSH password (defaults from vars file ssh_password)
  --ssh-key-path PATH          SSH key path
  --ssh-port PORT              Default: 22

  --skip-gitlab-clone-check    Skip clone check for dev1/dev2 demo repos
  --strict-harbor-check        Fail when Harbor(NodePort 30092) health check fails
  --gitlab-url URL             Internal GitLab URL for clone check (default: http://127.0.0.1:30089)

  --vmrun PATH                 vmrun.exe path
  --powershell-bin CMD         PowerShell binary (default: powershell.exe)
  --wait-vm-ip-timeout-sec N   Default: 600
  -h, --help                   Show this help

Examples:
  bash scripts/vmware_post_reboot_verify.sh \
    --vars-file packer/variables.vmware.auto.pkrvars.hcl \
    --control-plane-ip 192.168.56.10 \
    --ingress-lb-ip 192.168.56.240
EOF
}

is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  grep -qi microsoft /proc/version 2>/dev/null
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
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

to_windows_path() {
  local path="$1"
  if is_windows_style_path "${path}"; then
    printf '%s' "${path}"
    return 0
  fi
  wslpath -w "${path}"
}

normalize_win_path() {
  printf '%s' "${1//\\//}"
}

trim() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
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

ps_capture() {
  local command="$1"
  local tmp_out
  local tmp_err

  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"

  if "${POWERSHELL_BIN}" -NoProfile -Command "${command}" >"${tmp_out}" 2>"${tmp_err}"; then
    cat "${tmp_out}" | tr -d '\r'
    rm -f "${tmp_out}" "${tmp_err}"
    return 0
  fi

  cat "${tmp_err}" >&2 || true
  cat "${tmp_out}" >&2 || true
  rm -f "${tmp_out}" "${tmp_err}"
  return 1
}

resolve_output_dir() {
  local output_dir_raw
  output_dir_raw="$(read_packer_var "${PACKER_VARS}" output_directory)"
  if is_windows_style_path "${output_dir_raw}"; then
    OUTPUT_DIR_WSL="$(to_unix_path "${output_dir_raw}")"
  elif [[ "${output_dir_raw}" = /* ]]; then
    OUTPUT_DIR_WSL="${output_dir_raw}"
  else
    OUTPUT_DIR_WSL="${PACKER_DIR}/${output_dir_raw}"
  fi
}

resolve_vmrun() {
  local from_vars
  local candidate
  local unix_candidate
  local candidates=()

  candidates+=("${VMRUN_WIN}")

  from_vars="$(read_optional_packer_var "${PACKER_VARS}" vmware_workstation_path)"
  if [[ -n "${from_vars}" ]]; then
    if [[ "${from_vars,,}" == *vmrun.exe ]]; then
      candidates+=("${from_vars}")
    else
      from_vars="${from_vars%/}"
      from_vars="${from_vars%\\}"
      candidates+=("${from_vars}/vmrun.exe")
    fi
  fi

  candidates+=(
    "C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
    "C:/Program Files/VMware/VMware Workstation/vmrun.exe"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    unix_candidate="$(to_unix_path "${candidate}")"
    if [[ -f "${unix_candidate}" ]]; then
      VMRUN_WIN="$(normalize_win_path "$(to_windows_path "${unix_candidate}")")"
      return 0
    fi
  done

  die "vmrun.exe not found. Use --vmrun or set vmware_workstation_path in vars file."
}

wait_for_vm_ip() {
  local vmx_win="$1"
  local label="$2"
  local attempts
  local ip
  local i

  attempts=$(( WAIT_VM_IP_TIMEOUT_SEC / 5 ))
  if [[ "${attempts}" -lt 1 ]]; then
    attempts=1
  fi

  for i in $(seq 1 "${attempts}"); do
    ip="$(
      ps_capture "\$ip = & '${VMRUN_WIN}' getGuestIPAddress '${vmx_win}' 2>\$null; if (\$LASTEXITCODE -eq 0) { \$ip }" \
        | tail -n 1
    )"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done

  die "Timed out waiting VM guest IP (${label}) via vmrun."
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

ssh_run() {
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

wait_for_ssh() {
  local host="$1"
  local label="$2"
  local attempt

  for attempt in $(seq 1 60); do
    if ssh_run "${host}" "echo ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  die "Timed out waiting SSH (${label}): ${host}"
}

remote_kubectl() {
  local host="$1"
  shift
  ssh_run_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl $*"
}

resolve_ingress_lb_ip() {
  local host="$1"
  local attempts=90
  local i
  local ip=""

  if [[ -n "${INGRESS_LB_IP}" ]]; then
    printf '%s' "${INGRESS_LB_IP}"
    return 0
  fi

  for i in $(seq 1 "${attempts}"); do
    ip="$(
      ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n ingress-nginx get svc ingress-nginx-controller -o custom-columns=IP:.status.loadBalancer.ingress[0].ip --no-headers 2>/dev/null | tr -d '[:space:]'" \
        || true
    )"
    if [[ -n "${ip}" && "${ip}" != "<none>" ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done

  return 1
}

validate_cluster_state() {
  local host="$1"
  local not_ready_pods
  local unbound_pvc

  remote_kubectl "${host}" "wait --for=condition=Ready node/${CONTROL_PLANE_NAME} --timeout=420s"
  remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER1_NAME} --timeout=420s"
  remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER2_NAME} --timeout=420s"
  if ssh_run_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get node '${WORKER3_NAME}' >/dev/null 2>&1"; then
    remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER3_NAME} --timeout=420s"
  else
    log "Worker-3 node '${WORKER3_NAME}' not found; skipping worker-3 readiness wait."
  fi

  not_ready_pods="$(
    ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods --no-headers | awk '\$3 != \"Running\" && \$3 != \"Completed\" { print \$1 \" \" \$3 }'" || true
  )"
  if [[ -n "${not_ready_pods}" ]]; then
    printf '%s\n' "${not_ready_pods}"
    die "Not-ready pods detected in namespace ${NAMESPACE}."
  fi

  unbound_pvc="$(
    ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pvc --no-headers | awk '\$2 != \"Bound\" { print \$1 \" \" \$2 }'" || true
  )"
  if [[ -n "${unbound_pvc}" ]]; then
    printf '%s\n' "${unbound_pvc}"
    die "Unbound PVC detected in namespace ${NAMESPACE}."
  fi

  remote_kubectl "${host}" "get nodes -o wide"
  remote_kubectl "${host}" "-n ${NAMESPACE} get pods -o wide"
  remote_kubectl "${host}" "-n ${NAMESPACE} get pvc"
  remote_kubectl "${host}" "-n ${NAMESPACE} get ingress"
}

verify_http_endpoints() {
  local host="$1"
  local verify_script
  local verify_help

  if ! RESOLVED_INGRESS_LB_IP="$(resolve_ingress_lb_ip "${host}")"; then
    die "Unable to resolve ingress-nginx external IP. Use --ingress-lb-ip."
  fi
  log "Resolved ingress LB IP: ${RESOLVED_INGRESS_LB_IP}"

  verify_script="${REMOTE_REPO_ROOT}/scripts/verify.sh"
  verify_help="$(
    ssh_capture_sudo "${host}" "bash '${verify_script}' --help 2>&1 || true" || true
  )"

  if printf '%s' "${verify_help}" | grep -q -- '--http-mode'; then
    ssh_run_sudo "${host}" "bash '${verify_script}' --env '${ENVIRONMENT}' --http-mode ingress --lb-ip '${RESOLVED_INGRESS_LB_IP}'"
    return 0
  fi

  log "Remote verify.sh is legacy (no --http-mode). Running NodePort checks + ingress curl fallback."
  ssh_run_sudo "${host}" "bash '${verify_script}' --env '${ENVIRONMENT}' --skip-http"
  if [[ "${ENVIRONMENT}" == "dev" ]]; then
    ssh_run_sudo "${host}" "set -euo pipefail; \
      curl -fsS -H 'Host: dev.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/' >/dev/null; \
      curl -fsS -H 'Host: dev-api.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/docs' >/dev/null; \
      curl -fsS -H 'Host: jupyter.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/lab' >/dev/null; \
      curl -fsS -H 'Host: gitlab.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/users/sign_in' >/dev/null; \
      curl -fsS -H 'Host: airflow.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/' >/dev/null; \
      curl -fsS -H 'Host: nexus.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/' >/dev/null"
    return 0
  fi

  ssh_run_sudo "${host}" "set -euo pipefail; \
    curl -fsS -H 'Host: www.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/' >/dev/null; \
    curl -fsS -H 'Host: api.platform.local' 'http://${RESOLVED_INGRESS_LB_IP}/docs' >/dev/null"
}

check_harbor_endpoint() {
  local host="$1"
  local code

  code="$(
    ssh_capture "${host}" "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:30092 || true" \
      | tr -d '[:space:]'
  )"
  if [[ -n "${code}" && "${code}" != "000" ]]; then
    log "Harbor NodePort check passed (http://127.0.0.1:30092, HTTP ${code})"
    return 0
  fi

  if [[ "${STRICT_HARBOR_CHECK}" -eq 1 ]]; then
    die "Harbor NodePort health check failed (http://127.0.0.1:30092)."
  fi
  log "WARNING: Harbor NodePort health check failed (http://127.0.0.1:30092). Continuing (non-strict mode)."
}

verify_gitlab_clone_access() {
  local host="$1"
  local remote_cmd

  remote_cmd="set -euo pipefail; tmp_dir=\"\$(mktemp -d)\"; trap 'rm -rf \"\${tmp_dir}\"' EXIT; git clone --depth 1 \"${GITLAB_INTERNAL_URL}/dev1/platform-backend.git\" \"\${tmp_dir}/platform-backend\" >/dev/null; git clone --depth 1 \"${GITLAB_INTERNAL_URL}/dev2/platform-frontend.git\" \"\${tmp_dir}/platform-frontend\" >/dev/null; test -f \"\${tmp_dir}/platform-backend/README.md\"; test -f \"\${tmp_dir}/platform-frontend/README.md\""
  ssh_run_sudo "${host}" "${remote_cmd}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
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
    --control-plane-ip)
      [[ $# -ge 2 ]] || die "--control-plane-ip requires a value"
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --ingress-lb-ip)
      [[ $# -ge 2 ]] || die "--ingress-lb-ip requires a value"
      INGRESS_LB_IP="$2"
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
    --skip-gitlab-clone-check)
      SKIP_GITLAB_CLONE_CHECK=1
      shift
      ;;
    --strict-harbor-check)
      STRICT_HARBOR_CHECK=1
      shift
      ;;
    --gitlab-url)
      [[ $# -ge 2 ]] || die "--gitlab-url requires a value"
      GITLAB_INTERNAL_URL="$2"
      shift 2
      ;;
    --vmrun)
      [[ $# -ge 2 ]] || die "--vmrun requires a value"
      VMRUN_WIN="$2"
      shift 2
      ;;
    --powershell-bin)
      [[ $# -ge 2 ]] || die "--powershell-bin requires a value"
      POWERSHELL_BIN="$2"
      shift 2
      ;;
    --wait-vm-ip-timeout-sec)
      [[ $# -ge 2 ]] || die "--wait-vm-ip-timeout-sec requires a value"
      WAIT_VM_IP_TIMEOUT_SEC="$2"
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

is_wsl || die "This script must run in WSL."
require_command bash
require_command awk
require_command ssh
require_command wslpath
require_command "${POWERSHELL_BIN}"

if is_windows_style_path "${PACKER_VARS}"; then
  PACKER_VARS="$(to_unix_path "${PACKER_VARS}")"
fi
[[ -f "${PACKER_VARS}" ]] || die "Packer vars file not found: ${PACKER_VARS}"

if [[ -z "${SSH_USER}" ]]; then
  SSH_USER="$(read_packer_var "${PACKER_VARS}" ssh_username)"
fi
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_KEY_PATH}" ]]; then
  SSH_PASSWORD="$(read_optional_packer_var "${PACKER_VARS}" ssh_password)"
fi
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi
if [[ -n "${SSH_KEY_PATH}" ]]; then
  [[ -f "${SSH_KEY_PATH}" ]] || die "SSH key path not found: ${SSH_KEY_PATH}"
fi

SSH_OPTS=(
  -p "${SSH_PORT}"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=8
)
if [[ -n "${SSH_KEY_PATH}" ]]; then
  SSH_OPTS+=(-i "${SSH_KEY_PATH}")
fi

NAMESPACE="data-platform-${ENVIRONMENT}"

if [[ -n "${CONTROL_PLANE_IP}" ]]; then
  CONTROL_PLANE_SSH_HOST="${CONTROL_PLANE_IP}"
else
  resolve_output_dir
  resolve_vmrun
  CONTROL_PLANE_VMX_WIN="$(normalize_win_path "$(to_windows_path "${OUTPUT_DIR_WSL}/${CONTROL_PLANE_NAME}.vmx")")"
  CONTROL_PLANE_SSH_HOST="$(wait_for_vm_ip "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}")"
fi

log "Control-plane SSH endpoint: ${CONTROL_PLANE_SSH_HOST}"
wait_for_ssh "${CONTROL_PLANE_SSH_HOST}" "control-plane"

log "Checking cluster readiness (control-plane + worker1/worker2 + optional worker3)"
validate_cluster_state "${CONTROL_PLANE_SSH_HOST}"

log "Checking ingress URL endpoints"
verify_http_endpoints "${CONTROL_PLANE_SSH_HOST}"
check_harbor_endpoint "${CONTROL_PLANE_SSH_HOST}"

if [[ "${SKIP_GITLAB_CLONE_CHECK}" -eq 0 ]]; then
  log "Checking GitLab clone access for backend/frontend demo repos"
  verify_gitlab_clone_access "${CONTROL_PLANE_SSH_HOST}"
fi

log "Post-reboot verification completed."
if [[ -n "${RESOLVED_INGRESS_LB_IP}" ]]; then
  log "hosts example: ${RESOLVED_INGRESS_LB_IP} dev.platform.local dev-api.platform.local www.platform.local api.platform.local jupyter.platform.local gitlab.platform.local airflow.platform.local nexus.platform.local"
fi
