#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"

CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-data-platform}"
WORKER1_NAME="${WORKER1_NAME:-k8s-worker-1}"
WORKER2_NAME="${WORKER2_NAME:-k8s-worker-2}"
WORKER3_NAME="${WORKER3_NAME:-k8s-worker-3}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
OVERLAY="${OVERLAY:-dev-3node}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"

POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
VMRUN_WIN="${VMRUN_WIN:-C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe}"

VM_START_MODE="${VM_START_MODE:-nogui}"
WAIT_VM_IP_TIMEOUT_SEC="${WAIT_VM_IP_TIMEOUT_SEC:-600}"

STATIC_NETWORK=0
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.56.10}"
WORKER1_IP="${WORKER1_IP:-192.168.56.11}"
WORKER2_IP="${WORKER2_IP:-192.168.56.12}"
WORKER3_IP="${WORKER3_IP:-192.168.56.13}"
GATEWAY="${GATEWAY:-192.168.56.1}"
NETWORK_CIDR_PREFIX="${NETWORK_CIDR_PREFIX:-24}"
DNS_SERVERS="${DNS_SERVERS:-}"
NET_INTERFACE="${NET_INTERFACE:-}"

METALLB_ADDRESS_RANGE="${METALLB_ADDRESS_RANGE:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
SETUP_INGRESS_STACK=1

SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

FORCE_BUILD=0
FORCE_RECREATE_WORKERS=0
SKIP_BUILD=0
SKIP_NEXUS_PRIME=0
SKIP_EXPORT=1
POST_REBOOT_CHECK=0
SEED_GITLAB_BE_FE=0
ALWAYS_PROVISION=0
STRICT_HARBOR_CHECK=0
SKIP_NODE_NETWORK_FIX=0

NAMESPACE=""
CONTROL_PLANE_SSH_HOST=""
WORKER1_SSH_HOST=""
WORKER2_SSH_HOST=""
WORKER3_SSH_HOST=""
OUTPUT_DIR_WSL=""
CONTROL_PLANE_VMX_WIN=""
CONTROL_PLANE_VMX_WSL=""
WORKER1_VMX_WIN=""
WORKER2_VMX_WIN=""
WORKER3_VMX_WIN=""
WORKER1_VMX_WSL=""
WORKER2_VMX_WSL=""
WORKER3_VMX_WSL=""
RUN_PROVISION=1

NEXUS_URL="${NEXUS_URL:-http://127.0.0.1:30091}"
NEXUS_USERNAME="${NEXUS_USERNAME:-admin}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-nexus123!}"
NEXUS_CURRENT_PASSWORD="${NEXUS_CURRENT_PASSWORD:-}"
NEXUS_TARGET_PASSWORD="${NEXUS_TARGET_PASSWORD:-nexus123!}"
PYTHON_SEED_FILE_REMOTE="${PYTHON_SEED_FILE_REMOTE:-}"
NPM_SEED_FILE_REMOTE="${NPM_SEED_FILE_REMOTE:-}"
GITLAB_DEMO_PASSWORD="${GITLAB_DEMO_PASSWORD:-123456}"

log() {
  printf '[start.sh] %s\n' "$*"
}

warn() {
  printf '[start.sh] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[start.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash start.sh [options]

End-to-end VMware pipeline (control-plane + worker1/2/3):
  1) VM 재구성 + kubeadm join + dev-3node overlay + ingress/metallb
  2) 노드/파드/PVC/노드 배치 검증
  3) verify.sh URL 점검
  4) GitLab BE/FE repo seed (선택)
  5) Nexus 오프라인 캐시 워밍 (선택)
  6) 재부팅 복원 점검(선택)
  7) 4개 OVA export (옵션)

Default optimization:
  - 기존 VMX 4개(control-plane/worker1/worker2/worker3)가 이미 있으면
    packer/provision 단계를 건너뛰고 VM 기동 + 검증 중심으로 실행합니다.

Options:
  --vars-file PATH             Packer vars file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --dist-dir PATH              OVA output dir (default: C:/ffmpeg)

  --control-plane-name NAME    Default: k8s-data-platform
  --worker1-name NAME          Default: k8s-worker-1
  --worker2-name NAME          Default: k8s-worker-2
  --worker3-name NAME          Default: k8s-worker-3

  --env dev|prod               Default: dev
  --overlay NAME               Default: dev-3node
  --remote-repo-root PATH      Default: /opt/k8s-data-platform

  --skip-build                 Reuse existing control-plane VM build
  --force-build                Force packer rebuild for control-plane VM
  --force-recreate-workers     Force worker clone recreation
  --always-provision           Even if 4 VMX files exist, run provision/bootstrap step
  --no-force-build             (Legacy) same as default behavior
  --no-recreate-workers        (Legacy) same as default behavior
  --vm-start-mode gui|nogui    Default: nogui

  --static-network             Enable static IP bootstrap (recommended for reproducible OVA)
  --control-plane-ip IP        Default: 192.168.56.10
  --worker1-ip IP              Default: 192.168.56.11
  --worker2-ip IP              Default: 192.168.56.12
  --worker3-ip IP              Default: 192.168.56.13
  --gateway IP                 Default: 192.168.56.1
  --network-cidr-prefix N      Default: 24
  --dns-servers CSV            Default(static network): <gateway>,1.1.1.1,8.8.8.8
  --net-interface IFACE        Optional net interface override

  --metallb-range RANGE        Example: 192.168.56.240-192.168.56.250
  --ingress-lb-ip IP           Example: 192.168.56.240
  --skip-ingress-setup         Skip ingress/metallb setup
  --skip-node-network-fix      Skip automatic kubelet(:10250)/DNS timeout fix on all nodes

  --ssh-user USER              Override SSH user (defaults from vars file ssh_username)
  --ssh-password PASS          Override SSH password (defaults from vars file ssh_password)
  --ssh-key-path PATH          SSH key path
  --ssh-port PORT              Default: 22

  --skip-nexus-prime           Skip setup_nexus_offline.sh
  --nexus-url URL              Default: http://127.0.0.1:30091 (run on control-plane)
  --nexus-username USER        Default: admin
  --nexus-password PASS        Default: nexus123!
  --nexus-current-password PW  For re-bootstrap with changed admin password
  --nexus-target-password PW   Default: nexus123!
  --python-seed-file-remote P  Default: /opt/k8s-data-platform/scripts/offline/python-dev-seed.txt
  --npm-seed-file-remote P     Default: /opt/k8s-data-platform/scripts/offline/npm-dev-seed.txt
  --seed-gitlab-be-fe          Run scripts/demo_gitlab_repo_flow.sh on control-plane
  --gitlab-demo-password PASS  Demo user password for GitLab seed (default: 123456)
  --strict-harbor-check        Fail when Harbor(NodePort 30092) health check fails
  --post-reboot-check          Power-cycle VMs and re-run cluster/http checks

  --export                     Run vmware_export_3node_ova.sh from start.sh
  --skip-export                Skip vmware_export_3node_ova.sh (default)
  --vmrun PATH                 vmrun.exe path
  --powershell-bin CMD         PowerShell binary (default: powershell.exe)
  --wait-vm-ip-timeout-sec N   Default: 600
  -h, --help                   Show this help

Examples:
  bash start.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl

  bash start.sh --static-network \
    --control-plane-ip 192.168.56.10 \
    --worker1-ip 192.168.56.11 \
    --worker2-ip 192.168.56.12 \
    --worker3-ip 192.168.56.13 \
    --gateway 192.168.56.1 \
    --metallb-range 192.168.56.240-192.168.56.250 \
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

ps_run() {
  local command="$1"
  local tmp_out
  local tmp_err

  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"

  if "${POWERSHELL_BIN}" -NoProfile -Command "${command}" >"${tmp_out}" 2>"${tmp_err}"; then
    cat "${tmp_out}"
    rm -f "${tmp_out}" "${tmp_err}"
    return 0
  fi

  cat "${tmp_err}" >&2 || true
  cat "${tmp_out}" >&2 || true
  rm -f "${tmp_out}" "${tmp_err}"
  return 1
}

escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
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

vm_is_running() {
  local vmx_win="$1"
  local running

  running="$(
    ps_capture "\$target='${vmx_win}'; \$items = & '${VMRUN_WIN}' list 2>\$null; if (\$LASTEXITCODE -ne 0) { exit 1 }; \$joined = (\$items -join [Environment]::NewLine).ToLowerInvariant(); if (\$joined.Contains(\$target.ToLowerInvariant())) { '1' } else { '0' }"
  )" || return 1

  [[ "$(printf '%s' "${running}" | tr -d '[:space:]')" == "1" ]]
}

stop_vm_if_running() {
  local vmx_win="$1"
  local label="$2"
  if vm_is_running "${vmx_win}"; then
    log "Stopping VM (${label})"
    ps_run "& '${VMRUN_WIN}' stop '${vmx_win}' soft; if (\$LASTEXITCODE -ne 0) { & '${VMRUN_WIN}' stop '${vmx_win}' hard }"
  fi
}

start_vm_if_needed() {
  local vmx_win="$1"
  local label="$2"
  if vm_is_running "${vmx_win}"; then
    log "VM already running (${label})"
    return 0
  fi
  log "Starting VM (${label}) mode=${VM_START_MODE}"
  ps_run "& '${VMRUN_WIN}' start '${vmx_win}' '${VM_START_MODE}'"
}

SSH_OPTS=()
SCP_OPTS=()

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

scp_copy() {
  local src="$1"
  local host="$2"
  local dst="$3"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e scp "${SCP_OPTS[@]}" "${src}" "${SSH_USER}@${host}:${dst}"
    return
  fi

  scp "${SCP_OPTS[@]}" "${src}" "${SSH_USER}@${host}:${dst}"
}

sudo_wrap_command() {
  local command="$1"
  local escaped_pw
  local escaped_command

  escaped_command="$(escape_single_quotes "${command}")"
  if [[ -n "${SSH_PASSWORD}" ]]; then
    escaped_pw="$(escape_single_quotes "${SSH_PASSWORD}")"
    printf "printf '%%s\\n' '%s' | sudo -S -p '' bash -lc '%s'" "${escaped_pw}" "${escaped_command}"
    return 0
  fi

  printf "sudo bash -lc '%s'" "${escaped_command}"
}

ssh_capture_sudo() {
  local host="$1"
  local command="$2"

  ssh_capture "${host}" "$(sudo_wrap_command "${command}")"
}

ssh_run_sudo() {
  local host="$1"
  local command="$2"

  ssh_run "${host}" "$(sudo_wrap_command "${command}")"
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

resolve_worker_ssh_hosts() {
  if [[ -n "${WORKER1_SSH_HOST}" && -n "${WORKER2_SSH_HOST}" && -n "${WORKER3_SSH_HOST}" ]]; then
    return 0
  fi

  if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
    WORKER1_SSH_HOST="${WORKER1_IP}"
    WORKER2_SSH_HOST="${WORKER2_IP}"
    WORKER3_SSH_HOST="${WORKER3_IP}"
    return 0
  fi

  WORKER1_SSH_HOST="$(wait_for_vm_ip "${WORKER1_VMX_WIN}" "${WORKER1_NAME}")"
  WORKER2_SSH_HOST="$(wait_for_vm_ip "${WORKER2_VMX_WIN}" "${WORKER2_NAME}")"
  WORKER3_SSH_HOST="$(wait_for_vm_ip "${WORKER3_VMX_WIN}" "${WORKER3_NAME}")"
}

apply_node_runtime_fixes() {
  local fix_script_local="${ROOT_DIR}/scripts/fix_kubelet_network_timeouts.sh"
  local fix_script_remote="/tmp/fix_kubelet_network_timeouts.sh"
  local entry
  local label
  local host
  declare -A seen_hosts=()

  [[ -f "${fix_script_local}" ]] || die "Missing node fix script: ${fix_script_local}"
  resolve_worker_ssh_hosts

  for entry in \
    "control-plane:${CONTROL_PLANE_SSH_HOST}" \
    "worker-1:${WORKER1_SSH_HOST}" \
    "worker-2:${WORKER2_SSH_HOST}" \
    "worker-3:${WORKER3_SSH_HOST}"; do
    label="${entry%%:*}"
    host="${entry#*:}"
    [[ -n "${host}" ]] || die "Unable to resolve SSH host for ${label}"

    if [[ -n "${seen_hosts[$host]:-}" ]]; then
      warn "Skipping duplicate node host mapping (${label} -> ${host}, already fixed as ${seen_hosts[$host]})."
      continue
    fi
    seen_hosts["${host}"]="${label}"

    log "Applying kubelet/DNS timeout fix on ${label} (${host})"
    wait_for_ssh "${host}" "${label} before node fix"
    scp_copy "${fix_script_local}" "${host}" "${fix_script_remote}"
    ssh_run "${host}" "chmod +x '${fix_script_remote}'"
    ssh_run_sudo "${host}" "bash '${fix_script_remote}' --dns-servers '${DNS_SERVERS}'"
  done
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

verify_solution_placement() {
  local host="$1"
  local backend_node
  local jupyter_node
  local gitlab_node
  local nexus_node
  local mongodb_node
  local redis_node
  local airflow_node
  local frontend_nodes
  local worker3_pod_count

  backend_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=backend -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${backend_node}" ]] || die "backend pod node 확인 실패"
  [[ "${backend_node}" == "${WORKER1_NAME}" ]] || die "backend expected on ${WORKER1_NAME}, got ${backend_node}"

  jupyter_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=jupyter -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${jupyter_node}" ]] || die "jupyter pod node 확인 실패"
  [[ "${jupyter_node}" == "${WORKER1_NAME}" ]] || die "jupyter expected on ${WORKER1_NAME}, got ${jupyter_node}"

  gitlab_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=gitlab -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${gitlab_node}" ]] || die "gitlab pod node 확인 실패"
  [[ "${gitlab_node}" == "${WORKER2_NAME}" ]] || die "gitlab expected on ${WORKER2_NAME}, got ${gitlab_node}"

  nexus_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=nexus -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${nexus_node}" ]] || die "nexus pod node 확인 실패"
  [[ "${nexus_node}" == "${WORKER2_NAME}" ]] || die "nexus expected on ${WORKER2_NAME}, got ${nexus_node}"

  mongodb_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=mongodb -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${mongodb_node}" ]] || die "mongodb pod node 확인 실패"
  [[ "${mongodb_node}" == "${WORKER2_NAME}" ]] || die "mongodb expected on ${WORKER2_NAME}, got ${mongodb_node}"

  redis_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=redis -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${redis_node}" ]] || die "redis pod node 확인 실패"
  [[ "${redis_node}" == "${WORKER2_NAME}" ]] || die "redis expected on ${WORKER2_NAME}, got ${redis_node}"

  airflow_node="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=airflow -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  if [[ -n "${airflow_node}" ]]; then
    [[ "${airflow_node}" == "${WORKER2_NAME}" ]] || die "airflow expected on ${WORKER2_NAME}, got ${airflow_node}"
  fi

  frontend_nodes="$(ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -l app=frontend -o custom-columns=NODE:.spec.nodeName --no-headers | sed '/^$/d'")"
  [[ -n "${frontend_nodes}" ]] || die "frontend pod node 확인 실패"

  if printf '%s\n' "${frontend_nodes}" | grep -Fxq "${CONTROL_PLANE_NAME}"; then
    die "frontend pod must not be scheduled on control-plane (${CONTROL_PLANE_NAME})"
  fi
  if ! printf '%s\n' "${frontend_nodes}" | grep -Fxq "${WORKER1_NAME}" && ! printf '%s\n' "${frontend_nodes}" | grep -Fxq "${WORKER2_NAME}" && ! printf '%s\n' "${frontend_nodes}" | grep -Fxq "${WORKER3_NAME}"; then
    die "frontend pod가 worker 노드(${WORKER1_NAME}/${WORKER2_NAME}/${WORKER3_NAME})에 스케줄되지 않았습니다."
  fi

  worker3_pod_count="$(
    ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pods -o custom-columns=NODE:.spec.nodeName --no-headers | awk '\$1 == \"${WORKER3_NAME}\" { c++ } END { print c+0 }'" \
      | tr -d '\r[:space:]'
  )"
  [[ "${worker3_pod_count}" =~ ^[0-9]+$ ]] || worker3_pod_count=0
  (( worker3_pod_count > 0 )) || die "namespace ${NAMESPACE} workload가 ${WORKER3_NAME}에 배치되지 않았습니다."
}

validate_cluster_state() {
  local host="$1"
  local not_ready_pods
  local unbound_pvc

  remote_kubectl "${host}" "wait --for=condition=Ready node/${CONTROL_PLANE_NAME} --timeout=420s"
  remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER1_NAME} --timeout=420s"
  remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER2_NAME} --timeout=420s"
  remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER3_NAME} --timeout=420s"

  for deploy in backend jupyter frontend gitlab nexus redis; do
    remote_kubectl "${host}" "-n ${NAMESPACE} wait --for=condition=Available deployment/${deploy} --timeout=900s"
  done
  if ssh_run_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get deployment airflow >/dev/null 2>&1"; then
    remote_kubectl "${host}" "-n ${NAMESPACE} wait --for=condition=Available deployment/airflow --timeout=900s"
  fi
  if ssh_run_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get statefulset mongodb >/dev/null 2>&1"; then
    remote_kubectl "${host}" "-n ${NAMESPACE} wait --for=condition=Ready pod -l app=mongodb --timeout=900s"
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

  verify_solution_placement "${host}"

  remote_kubectl "${host}" "get nodes -o wide"
  remote_kubectl "${host}" "-n ${NAMESPACE} get pods -o wide"
  remote_kubectl "${host}" "-n ${NAMESPACE} get pvc"
  remote_kubectl "${host}" "-n ${NAMESPACE} get ingress"
}

verify_http_endpoints() {
  local host="$1"
  local verify_supports_http_mode=0

  local check_nodeport_http
  check_nodeport_http() {
    local name="$1"
    local url="$2"
    local accepted_codes="$3"
    local code

    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "${url}" || true)"
    if printf '%s\n' "${accepted_codes}" | tr ',' '\n' | grep -Fxq "${code}"; then
      log "HTTP check passed (${name}: ${url}, status=${code})"
      return 0
    fi
    die "HTTP check failed (${name}: ${url}, status=${code}, expected=${accepted_codes})"
  }

  if ssh_run_sudo "${host}" "bash '${REMOTE_REPO_ROOT}/scripts/verify.sh' --help 2>/dev/null | grep -q -- '--http-mode'"; then
    verify_supports_http_mode=1
  fi

  if [[ "${verify_supports_http_mode}" -eq 0 ]]; then
    warn "Remote verify.sh does not support --http-mode. Using legacy NodePort verification flags."
    ssh_run_sudo "${host}" "bash '${REMOTE_REPO_ROOT}/scripts/verify.sh' --env '${ENVIRONMENT}' --host '${host}' --skip-http"
    check_nodeport_http "frontend" "http://${host}:30080" "200"
    check_nodeport_http "backend" "http://${host}:30081/docs" "200"
    check_nodeport_http "jupyter" "http://${host}:30088/lab" "200,302"
    check_nodeport_http "gitlab" "http://${host}:30089/users/sign_in" "200,302"
    check_nodeport_http "nexus" "http://${host}:30091" "200,302"
    return 0
  fi

  if [[ "${SETUP_INGRESS_STACK}" -eq 1 ]]; then
    if RESOLVED_INGRESS_LB_IP="$(resolve_ingress_lb_ip "${host}")"; then
      log "Resolved ingress LB IP: ${RESOLVED_INGRESS_LB_IP}"
      ssh_run_sudo "${host}" "bash '${REMOTE_REPO_ROOT}/scripts/verify.sh' --env '${ENVIRONMENT}' --http-mode ingress --lb-ip '${RESOLVED_INGRESS_LB_IP}'"
      return 0
    fi
    warn "Unable to resolve ingress-nginx external IP. Falling back to NodePort verification."
  fi
  ssh_run_sudo "${host}" "bash '${REMOTE_REPO_ROOT}/scripts/verify.sh' --env '${ENVIRONMENT}' --http-mode nodeport --host '${host}'"
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
  warn "Harbor NodePort health check failed (http://127.0.0.1:30092). Continuing (non-strict mode)."
}

seed_gitlab_be_fe_repositories() {
  local host="$1"
  local escaped_namespace
  local escaped_repo_root
  local escaped_demo_pw
  local remote_cmd

  escaped_namespace="$(escape_single_quotes "${NAMESPACE}")"
  escaped_repo_root="$(escape_single_quotes "${REMOTE_REPO_ROOT}")"
  escaped_demo_pw="$(escape_single_quotes "${GITLAB_DEMO_PASSWORD}")"

  remote_cmd="bash -lc 'set -euo pipefail; NS='\''${escaped_namespace}'\''; REPO='\''${escaped_repo_root}'\''; DEMO_PW='\''${escaped_demo_pw}'\''; ROOT_PW=\"\$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n \"\${NS}\" get secret platform-secrets -o jsonpath=\"{.data.GITLAB_ROOT_PASSWORD}\" | base64 -d)\"; cd \"\${REPO}\"; NAMESPACE=\"\${NS}\" GITLAB_URL=\"http://127.0.0.1:30089\" GITLAB_ROOT_PASSWORD=\"\${ROOT_PW}\" GITLAB_DEMO_PASSWORD=\"\${DEMO_PW}\" bash scripts/demo_gitlab_repo_flow.sh'"

  ssh_run_sudo "${host}" "${remote_cmd}"
}

verify_gitlab_clone_access() {
  local host="$1"
  local remote_cmd

  remote_cmd="bash -lc 'set -euo pipefail; tmp_dir=\"\$(mktemp -d)\"; trap '\''rm -rf \"\${tmp_dir}\"'\'' EXIT; git clone --depth 1 \"http://127.0.0.1:30089/dev1/platform-backend.git\" \"\${tmp_dir}/platform-backend\" >/dev/null; git clone --depth 1 \"http://127.0.0.1:30089/dev2/platform-frontend.git\" \"\${tmp_dir}/platform-frontend\" >/dev/null; test -f \"\${tmp_dir}/platform-backend/README.md\"; test -f \"\${tmp_dir}/platform-frontend/README.md\"'"

  ssh_run_sudo "${host}" "${remote_cmd}"
}

resolve_nexus_prime_url() {
  local host="$1"
  local svc_ip
  local pod_ip
  local candidate_url
  local code
  local candidates=()
  declare -A seen_urls=()

  candidates+=("${NEXUS_URL}")
  candidates+=("http://127.0.0.1:30091")

  svc_ip="$(
    ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get svc nexus -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true" \
      | tr -d '\r[:space:]'
  )"
  pod_ip="$(
    ssh_capture_sudo "${host}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pod -l app=nexus -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true" \
      | tr -d '\r[:space:]'
  )"

  if [[ -n "${svc_ip}" ]]; then
    candidates+=("http://${svc_ip}:8081")
  fi
  if [[ -n "${pod_ip}" ]]; then
    candidates+=("http://${pod_ip}:8081")
  fi

  for candidate_url in "${candidates[@]}"; do
    [[ -n "${candidate_url}" ]] || continue
    if [[ -n "${seen_urls[${candidate_url}]:-}" ]]; then
      continue
    fi
    seen_urls["${candidate_url}"]=1

    code="$(
      ssh_capture_sudo "${host}" "curl -sS -o /dev/null -w '%{http_code}' --max-time 8 '${candidate_url}/service/rest/v1/status' || true" \
        | tr -d '\r[:space:]'
    )"
    if [[ "${code}" == "200" ]]; then
      printf '%s' "${candidate_url}"
      return 0
    fi
  done

  warn "Unable to auto-resolve reachable Nexus URL. Falling back to configured value: ${NEXUS_URL}"
  printf '%s' "${NEXUS_URL}"
}

resolve_nexus_prime_current_password() {
  local host="$1"
  local nexus_url="$2"
  local candidate
  local code
  local escaped_candidate
  local pod_admin_password
  local candidates=()
  declare -A seen_passwords=()

  candidates+=("${NEXUS_CURRENT_PASSWORD}")
  candidates+=("${NEXUS_PASSWORD}")
  candidates+=("${NEXUS_TARGET_PASSWORD}")

  pod_admin_password="$(
    ssh_capture_sudo "${host}" "set -euo pipefail; pod=\"\$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' get pod -l app=nexus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)\"; if [[ -n \"\${pod}\" ]]; then KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n '${NAMESPACE}' exec \"\${pod}\" -- cat /nexus-data/admin.password 2>/dev/null || true; fi" \
      | tr -d '\r[:space:]'
  )"
  if [[ -n "${pod_admin_password}" ]]; then
    candidates+=("${pod_admin_password}")
  fi

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    if [[ -n "${seen_passwords[${candidate}]:-}" ]]; then
      continue
    fi
    seen_passwords["${candidate}"]=1

    escaped_candidate="$(escape_single_quotes "${candidate}")"
    code="$(
      ssh_capture_sudo "${host}" "pw='${escaped_candidate}'; curl -sS -o /dev/null -w '%{http_code}' --max-time 8 -u \"admin:\${pw}\" '${nexus_url}/service/rest/v1/status' || true" \
        | tr -d '\r[:space:]'
    )"
    if [[ "${code}" == "200" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  return 1
}

run_nexus_prime() {
  local host="$1"
  local setup_script="${REMOTE_REPO_ROOT}/scripts/setup_nexus_offline.sh"
  local setup_help
  local supports_python_seed=0
  local supports_npm_seed=0
  local effective_nexus_url
  local effective_current_password=""
  local prime_password
  local escaped_namespace
  local escaped_nexus_url
  local escaped_target_password
  local escaped_username
  local escaped_prime_password
  local escaped_current_password
  local escaped_python_seed
  local escaped_npm_seed
  local cmd

  setup_help="$(ssh_capture_sudo "${host}" "bash '${setup_script}' --help 2>/dev/null || true")"
  if printf '%s\n' "${setup_help}" | grep -q -- '--python-seed-file'; then
    supports_python_seed=1
  fi
  if printf '%s\n' "${setup_help}" | grep -q -- '--npm-seed-file'; then
    supports_npm_seed=1
  fi

  effective_nexus_url="$(resolve_nexus_prime_url "${host}")"
  log "Nexus prime URL: ${effective_nexus_url}"

  if effective_current_password="$(resolve_nexus_prime_current_password "${host}" "${effective_nexus_url}")"; then
    log "Nexus admin credential resolved for bootstrap."
  else
    warn "Unable to verify Nexus current admin password automatically. Falling back to provided values."
    effective_current_password="${NEXUS_CURRENT_PASSWORD}"
  fi

  prime_password="${NEXUS_PASSWORD}"
  if [[ "${NEXUS_USERNAME}" == "admin" ]]; then
    prime_password="${NEXUS_TARGET_PASSWORD}"
  fi

  escaped_namespace="$(escape_single_quotes "${NAMESPACE}")"
  escaped_nexus_url="$(escape_single_quotes "${effective_nexus_url}")"
  escaped_target_password="$(escape_single_quotes "${NEXUS_TARGET_PASSWORD}")"
  escaped_username="$(escape_single_quotes "${NEXUS_USERNAME}")"
  escaped_prime_password="$(escape_single_quotes "${prime_password}")"

  cmd="bash '${setup_script}' --namespace '${escaped_namespace}' --nexus-url '${escaped_nexus_url}' --target-password '${escaped_target_password}' --username '${escaped_username}' --password '${escaped_prime_password}'"

  if [[ -n "${effective_current_password}" ]]; then
    escaped_current_password="$(escape_single_quotes "${effective_current_password}")"
    cmd+=" --current-password '${escaped_current_password}'"
  fi

  if [[ -n "${PYTHON_SEED_FILE_REMOTE}" ]]; then
    if [[ "${supports_python_seed}" -eq 1 ]]; then
      escaped_python_seed="$(escape_single_quotes "${PYTHON_SEED_FILE_REMOTE}")"
      cmd+=" --python-seed-file '${escaped_python_seed}'"
    else
      warn "Remote setup_nexus_offline.sh does not support --python-seed-file. Skipping seed-file option."
    fi
  fi

  if [[ -n "${NPM_SEED_FILE_REMOTE}" ]]; then
    if [[ "${supports_npm_seed}" -eq 1 ]]; then
      escaped_npm_seed="$(escape_single_quotes "${NPM_SEED_FILE_REMOTE}")"
      cmd+=" --npm-seed-file '${escaped_npm_seed}'"
    else
      warn "Remote setup_nexus_offline.sh does not support --npm-seed-file. Skipping seed-file option."
    fi
  fi

  ssh_run_sudo "${host}" "${cmd}"
}

run_post_reboot_check() {
  log "Post-reboot check: power-cycling control-plane + 3 workers"
  stop_vm_if_running "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}"
  stop_vm_if_running "${WORKER1_VMX_WIN}" "${WORKER1_NAME}"
  stop_vm_if_running "${WORKER2_VMX_WIN}" "${WORKER2_NAME}"
  stop_vm_if_running "${WORKER3_VMX_WIN}" "${WORKER3_NAME}"
  sleep 3

  start_vm_if_needed "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}"
  start_vm_if_needed "${WORKER1_VMX_WIN}" "${WORKER1_NAME}"
  start_vm_if_needed "${WORKER2_VMX_WIN}" "${WORKER2_NAME}"
  start_vm_if_needed "${WORKER3_VMX_WIN}" "${WORKER3_NAME}"

  if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
    CONTROL_PLANE_SSH_HOST="${CONTROL_PLANE_IP}"
  else
    CONTROL_PLANE_SSH_HOST="$(wait_for_vm_ip "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}")"
  fi
  wait_for_ssh "${CONTROL_PLANE_SSH_HOST}" "control-plane after power-cycle"

  validate_cluster_state "${CONTROL_PLANE_SSH_HOST}"
  verify_http_endpoints "${CONTROL_PLANE_SSH_HOST}"
  check_harbor_endpoint "${CONTROL_PLANE_SSH_HOST}"
  if [[ "${SEED_GITLAB_BE_FE}" -eq 1 ]]; then
    verify_gitlab_clone_access "${CONTROL_PLANE_SSH_HOST}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || die "--dist-dir requires a value"
      DIST_DIR="$2"
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
    --overlay)
      [[ $# -ge 2 ]] || die "--overlay requires a value"
      OVERLAY="$2"
      shift 2
      ;;
    --remote-repo-root)
      [[ $# -ge 2 ]] || die "--remote-repo-root requires a value"
      REMOTE_REPO_ROOT="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --force-build)
      FORCE_BUILD=1
      shift
      ;;
    --force-recreate-workers)
      FORCE_RECREATE_WORKERS=1
      shift
      ;;
    --always-provision)
      ALWAYS_PROVISION=1
      shift
      ;;
    --no-force-build)
      FORCE_BUILD=0
      shift
      ;;
    --no-recreate-workers)
      FORCE_RECREATE_WORKERS=0
      shift
      ;;
    --vm-start-mode)
      [[ $# -ge 2 ]] || die "--vm-start-mode requires a value"
      VM_START_MODE="${2,,}"
      shift 2
      ;;
    --static-network)
      STATIC_NETWORK=1
      shift
      ;;
    --control-plane-ip)
      [[ $# -ge 2 ]] || die "--control-plane-ip requires a value"
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --worker1-ip)
      [[ $# -ge 2 ]] || die "--worker1-ip requires a value"
      WORKER1_IP="$2"
      shift 2
      ;;
    --worker2-ip)
      [[ $# -ge 2 ]] || die "--worker2-ip requires a value"
      WORKER2_IP="$2"
      shift 2
      ;;
    --worker3-ip)
      [[ $# -ge 2 ]] || die "--worker3-ip requires a value"
      WORKER3_IP="$2"
      shift 2
      ;;
    --gateway)
      [[ $# -ge 2 ]] || die "--gateway requires a value"
      GATEWAY="$2"
      shift 2
      ;;
    --network-cidr-prefix)
      [[ $# -ge 2 ]] || die "--network-cidr-prefix requires a value"
      NETWORK_CIDR_PREFIX="$2"
      shift 2
      ;;
    --dns-servers)
      [[ $# -ge 2 ]] || die "--dns-servers requires a value"
      DNS_SERVERS="$2"
      shift 2
      ;;
    --net-interface)
      [[ $# -ge 2 ]] || die "--net-interface requires a value"
      NET_INTERFACE="$2"
      shift 2
      ;;
    --metallb-range)
      [[ $# -ge 2 ]] || die "--metallb-range requires a value"
      METALLB_ADDRESS_RANGE="$2"
      shift 2
      ;;
    --ingress-lb-ip)
      [[ $# -ge 2 ]] || die "--ingress-lb-ip requires a value"
      INGRESS_LB_IP="$2"
      shift 2
      ;;
    --skip-ingress-setup)
      SETUP_INGRESS_STACK=0
      shift
      ;;
    --skip-node-network-fix)
      SKIP_NODE_NETWORK_FIX=1
      shift
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
    --skip-nexus-prime)
      SKIP_NEXUS_PRIME=1
      shift
      ;;
    --seed-gitlab-be-fe)
      SEED_GITLAB_BE_FE=1
      shift
      ;;
    --gitlab-demo-password)
      [[ $# -ge 2 ]] || die "--gitlab-demo-password requires a value"
      GITLAB_DEMO_PASSWORD="$2"
      shift 2
      ;;
    --strict-harbor-check)
      STRICT_HARBOR_CHECK=1
      shift
      ;;
    --post-reboot-check)
      POST_REBOOT_CHECK=1
      shift
      ;;
    --nexus-url)
      [[ $# -ge 2 ]] || die "--nexus-url requires a value"
      NEXUS_URL="$2"
      shift 2
      ;;
    --nexus-username)
      [[ $# -ge 2 ]] || die "--nexus-username requires a value"
      NEXUS_USERNAME="$2"
      shift 2
      ;;
    --nexus-password)
      [[ $# -ge 2 ]] || die "--nexus-password requires a value"
      NEXUS_PASSWORD="$2"
      shift 2
      ;;
    --nexus-current-password)
      [[ $# -ge 2 ]] || die "--nexus-current-password requires a value"
      NEXUS_CURRENT_PASSWORD="$2"
      shift 2
      ;;
    --nexus-target-password)
      [[ $# -ge 2 ]] || die "--nexus-target-password requires a value"
      NEXUS_TARGET_PASSWORD="$2"
      shift 2
      ;;
    --python-seed-file-remote)
      [[ $# -ge 2 ]] || die "--python-seed-file-remote requires a value"
      PYTHON_SEED_FILE_REMOTE="$2"
      shift 2
      ;;
    --npm-seed-file-remote)
      [[ $# -ge 2 ]] || die "--npm-seed-file-remote requires a value"
      NPM_SEED_FILE_REMOTE="$2"
      shift 2
      ;;
    --skip-export)
      SKIP_EXPORT=1
      shift
      ;;
    --export)
      SKIP_EXPORT=0
      shift
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

is_wsl || die "start.sh must run in WSL."

require_command bash
require_command awk
require_command ssh
require_command wslpath
require_command "${POWERSHELL_BIN}"

if is_windows_style_path "${PACKER_VARS}"; then
  PACKER_VARS="$(to_unix_path "${PACKER_VARS}")"
fi
[[ -f "${PACKER_VARS}" ]] || die "Packer vars file not found: ${PACKER_VARS}"

resolve_output_dir
resolve_vmrun

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

case "${VM_START_MODE}" in
  gui|nogui) ;;
  *)
    die "--vm-start-mode must be one of: gui, nogui"
    ;;
esac

if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
  [[ -n "${CONTROL_PLANE_IP}" ]] || die "CONTROL_PLANE_IP is required with --static-network"
  [[ -n "${WORKER1_IP}" ]] || die "WORKER1_IP is required with --static-network"
  [[ -n "${WORKER2_IP}" ]] || die "WORKER2_IP is required with --static-network"
  [[ -n "${WORKER3_IP}" ]] || die "WORKER3_IP is required with --static-network"
  [[ -n "${GATEWAY}" ]] || die "GATEWAY is required with --static-network"
  if [[ -z "${DNS_SERVERS}" ]]; then
    DNS_SERVERS="${GATEWAY},1.1.1.1,8.8.8.8"
  fi
fi

if [[ "${CONTROL_PLANE_NAME}" == "${WORKER1_NAME}" || "${CONTROL_PLANE_NAME}" == "${WORKER2_NAME}" || "${CONTROL_PLANE_NAME}" == "${WORKER3_NAME}" || "${WORKER1_NAME}" == "${WORKER2_NAME}" || "${WORKER1_NAME}" == "${WORKER3_NAME}" || "${WORKER2_NAME}" == "${WORKER3_NAME}" ]]; then
  die "VM names must be unique."
fi

if [[ -z "${PYTHON_SEED_FILE_REMOTE}" ]]; then
  PYTHON_SEED_FILE_REMOTE="${REMOTE_REPO_ROOT}/scripts/offline/python-dev-seed.txt"
fi
if [[ -z "${NPM_SEED_FILE_REMOTE}" ]]; then
  NPM_SEED_FILE_REMOTE="${REMOTE_REPO_ROOT}/scripts/offline/npm-dev-seed.txt"
fi

NAMESPACE="data-platform-${ENVIRONMENT}"
CONTROL_PLANE_VMX_WSL="${OUTPUT_DIR_WSL}/${CONTROL_PLANE_NAME}.vmx"
WORKER1_VMX_WSL="${OUTPUT_DIR_WSL}/${WORKER1_NAME}/${WORKER1_NAME}.vmx"
WORKER2_VMX_WSL="${OUTPUT_DIR_WSL}/${WORKER2_NAME}/${WORKER2_NAME}.vmx"
WORKER3_VMX_WSL="${OUTPUT_DIR_WSL}/${WORKER3_NAME}/${WORKER3_NAME}.vmx"

CONTROL_PLANE_VMX_WIN="$(normalize_win_path "$(to_windows_path "${CONTROL_PLANE_VMX_WSL}")")"
WORKER1_VMX_WIN="$(normalize_win_path "$(to_windows_path "${WORKER1_VMX_WSL}")")"
WORKER2_VMX_WIN="$(normalize_win_path "$(to_windows_path "${WORKER2_VMX_WSL}")")"
WORKER3_VMX_WIN="$(normalize_win_path "$(to_windows_path "${WORKER3_VMX_WSL}")")"

if [[ "${SKIP_BUILD}" -eq 0 && "${FORCE_BUILD}" -eq 0 && -f "${CONTROL_PLANE_VMX_WSL}" ]]; then
  SKIP_BUILD=1
  log "Existing control-plane VMX detected. Packer build will be skipped."
fi

if [[ "${ALWAYS_PROVISION}" -eq 0 && "${FORCE_BUILD}" -eq 0 && "${FORCE_RECREATE_WORKERS}" -eq 0 ]]; then
  if [[ -f "${CONTROL_PLANE_VMX_WSL}" && -f "${WORKER1_VMX_WSL}" && -f "${WORKER2_VMX_WSL}" && -f "${WORKER3_VMX_WSL}" ]]; then
    RUN_PROVISION=0
    log "Existing VMX set detected (control-plane + worker1/2/3). Provision/bootstrap step will be skipped."
  fi
fi

log "Execution Plan"
if [[ "${RUN_PROVISION}" -eq 1 ]]; then
  log "  - scripts/vmware_provision_3node.sh"
else
  log "  - Reuse existing VMX (start only, no packer/delete)"
fi
if [[ "${SKIP_NODE_NETWORK_FIX}" -eq 0 ]]; then
  log "  - Node runtime fixes (kubelet:10250 + DNS)"
fi
log "  - Cluster placement checks (nodes/pods/pvc)"
log "  - scripts/verify.sh"
if [[ "${SEED_GITLAB_BE_FE}" -eq 1 ]]; then
  log "  - scripts/demo_gitlab_repo_flow.sh (remote)"
fi
if [[ "${SKIP_NEXUS_PRIME}" -eq 0 ]]; then
  log "  - scripts/setup_nexus_offline.sh (remote)"
fi
if [[ "${POST_REBOOT_CHECK}" -eq 1 ]]; then
  log "  - Power-cycle control-plane + worker1/2/3 + re-check"
fi
if [[ "${SKIP_EXPORT}" -eq 0 ]]; then
  log "  - scripts/vmware_export_3node_ova.sh"
fi

TOTAL_STEPS=3
if [[ "${SKIP_NODE_NETWORK_FIX}" -eq 0 ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
fi
if [[ "${SEED_GITLAB_BE_FE}" -eq 1 ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
fi
if [[ "${SKIP_NEXUS_PRIME}" -eq 0 ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
fi
if [[ "${POST_REBOOT_CHECK}" -eq 1 ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
fi
if [[ "${SKIP_EXPORT}" -eq 0 ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
fi
STEP_INDEX=1

if [[ "${RUN_PROVISION}" -eq 1 ]]; then
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Rebuild/provision VMware cluster (control-plane + worker1/2/3)"
  provision_cmd=(
    bash "${ROOT_DIR}/scripts/vmware_provision_3node.sh"
    --vars-file "${PACKER_VARS}"
    --control-plane-name "${CONTROL_PLANE_NAME}"
    --worker1-name "${WORKER1_NAME}"
    --worker2-name "${WORKER2_NAME}"
    --worker3-name "${WORKER3_NAME}"
    --vmrun "${VMRUN_WIN}"
    --powershell-bin "${POWERSHELL_BIN}"
    --env "${ENVIRONMENT}"
    --overlay "${OVERLAY}"
    --remote-repo-root "${REMOTE_REPO_ROOT}"
    --vm-start-mode "${VM_START_MODE}"
    --ssh-port "${SSH_PORT}"
    --wait-ip-timeout-sec "${WAIT_VM_IP_TIMEOUT_SEC}"
  )

  if [[ "${SKIP_BUILD}" -eq 1 ]]; then
    provision_cmd+=(--skip-build)
  elif [[ "${FORCE_BUILD}" -eq 1 ]]; then
    provision_cmd+=(--force-build)
  fi

  if [[ "${FORCE_RECREATE_WORKERS}" -eq 1 ]]; then
    provision_cmd+=(--force-recreate-workers)
  fi
  if [[ "${SETUP_INGRESS_STACK}" -eq 0 ]]; then
    provision_cmd+=(--skip-ingress-setup)
  fi
  if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
    provision_cmd+=(
      --static-network
      --control-plane-ip "${CONTROL_PLANE_IP}"
      --worker1-ip "${WORKER1_IP}"
      --worker2-ip "${WORKER2_IP}"
      --worker3-ip "${WORKER3_IP}"
      --gateway "${GATEWAY}"
      --network-cidr-prefix "${NETWORK_CIDR_PREFIX}"
      --dns-servers "${DNS_SERVERS}"
    )
    if [[ -n "${NET_INTERFACE}" ]]; then
      provision_cmd+=(--net-interface "${NET_INTERFACE}")
    fi
  fi
  if [[ -n "${METALLB_ADDRESS_RANGE}" ]]; then
    provision_cmd+=(--metallb-range "${METALLB_ADDRESS_RANGE}")
  fi
  if [[ -n "${INGRESS_LB_IP}" ]]; then
    provision_cmd+=(--ingress-lb-ip "${INGRESS_LB_IP}")
  fi
  if [[ -n "${SSH_USER}" ]]; then
    provision_cmd+=(--ssh-user "${SSH_USER}")
  fi
  if [[ -n "${SSH_PASSWORD}" ]]; then
    provision_cmd+=(--ssh-password "${SSH_PASSWORD}")
  fi
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    provision_cmd+=(--ssh-key-path "${SSH_KEY_PATH}")
  fi

  "${provision_cmd[@]}"
else
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Reuse existing VMware VMs (no packer/delete)"
  [[ -f "${CONTROL_PLANE_VMX_WSL}" ]] || die "Missing VMX: ${CONTROL_PLANE_VMX_WSL}"
  [[ -f "${WORKER1_VMX_WSL}" ]] || die "Missing VMX: ${WORKER1_VMX_WSL}"
  [[ -f "${WORKER2_VMX_WSL}" ]] || die "Missing VMX: ${WORKER2_VMX_WSL}"
  [[ -f "${WORKER3_VMX_WSL}" ]] || die "Missing VMX: ${WORKER3_VMX_WSL}"
  start_vm_if_needed "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}"
  start_vm_if_needed "${WORKER1_VMX_WIN}" "${WORKER1_NAME}"
  start_vm_if_needed "${WORKER2_VMX_WIN}" "${WORKER2_NAME}"
  start_vm_if_needed "${WORKER3_VMX_WIN}" "${WORKER3_NAME}"
fi

STEP_INDEX=$(( STEP_INDEX + 1 ))
log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Resolve control-plane SSH endpoint"
if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
  CONTROL_PLANE_SSH_HOST="${CONTROL_PLANE_IP}"
else
  CONTROL_PLANE_SSH_HOST="$(wait_for_vm_ip "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}")"
fi
wait_for_ssh "${CONTROL_PLANE_SSH_HOST}" "control-plane"

STEP_INDEX=$(( STEP_INDEX + 1 ))
if [[ "${SKIP_NODE_NETWORK_FIX}" -eq 0 ]]; then
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Fix kubelet(:10250) and DNS timeout settings"
  apply_node_runtime_fixes
  STEP_INDEX=$(( STEP_INDEX + 1 ))
fi

log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Validate cluster placement and HTTP endpoints"
validate_cluster_state "${CONTROL_PLANE_SSH_HOST}"
verify_http_endpoints "${CONTROL_PLANE_SSH_HOST}"
check_harbor_endpoint "${CONTROL_PLANE_SSH_HOST}"

if [[ "${SEED_GITLAB_BE_FE}" -eq 1 ]]; then
  STEP_INDEX=$(( STEP_INDEX + 1 ))
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Seed GitLab backend/frontend repositories"
  seed_gitlab_be_fe_repositories "${CONTROL_PLANE_SSH_HOST}"
  log "GitLab clone accessibility check (dev1/platform-backend, dev2/platform-frontend)"
  verify_gitlab_clone_access "${CONTROL_PLANE_SSH_HOST}"
fi

if [[ "${SKIP_NEXUS_PRIME}" -eq 0 ]]; then
  STEP_INDEX=$(( STEP_INDEX + 1 ))
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Prime Nexus offline repositories"
  run_nexus_prime "${CONTROL_PLANE_SSH_HOST}"
fi

if [[ "${POST_REBOOT_CHECK}" -eq 1 ]]; then
  STEP_INDEX=$(( STEP_INDEX + 1 ))
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Post-reboot resilience check"
  run_post_reboot_check
fi

if [[ "${SKIP_EXPORT}" -eq 0 ]]; then
  STEP_INDEX=$(( STEP_INDEX + 1 ))
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Export OVA artifacts (control-plane + worker1/2/3)"
  export_cmd=(
    bash "${ROOT_DIR}/scripts/vmware_export_3node_ova.sh"
    --vars-file "${PACKER_VARS}"
    --dist-dir "${DIST_DIR}"
    --control-plane-name "${CONTROL_PLANE_NAME}"
    --worker1-name "${WORKER1_NAME}"
    --worker2-name "${WORKER2_NAME}"
    --worker3-name "${WORKER3_NAME}"
    --vmrun "${VMRUN_WIN}"
  )
  "${export_cmd[@]}"
fi

log "Completed."
log "Control-plane SSH host: ${CONTROL_PLANE_SSH_HOST}"
log "Post-PC-reboot verify command:"
log "  bash scripts/vmware_post_reboot_verify.sh --vars-file ${PACKER_VARS} --control-plane-ip ${CONTROL_PLANE_SSH_HOST}"
if [[ "${SETUP_INGRESS_STACK}" -eq 1 ]]; then
  log "Ingress URL: http://platform.local"
  log "Hosts example:"
  if [[ -n "${RESOLVED_INGRESS_LB_IP:-}" ]]; then
    log "  ${RESOLVED_INGRESS_LB_IP} platform.local jupyter.platform.local gitlab.platform.local airflow.platform.local nexus.platform.local"
  else
    log "  <INGRESS_LB_IP> platform.local jupyter.platform.local gitlab.platform.local airflow.platform.local nexus.platform.local"
  fi
fi
if [[ "${SKIP_EXPORT}" -eq 0 ]]; then
  log "OVA artifacts expected:"
  log "  ${DIST_DIR}/${CONTROL_PLANE_NAME}.ova"
  log "  ${DIST_DIR}/${WORKER1_NAME}.ova"
  log "  ${DIST_DIR}/${WORKER2_NAME}.ova"
  log "  ${DIST_DIR}/${WORKER3_NAME}.ova"
else
  log "OVA export is skipped by default. Run:"
  log "  bash ./ovabuild.sh --vars-file ${PACKER_VARS} --control-plane-ip ${CONTROL_PLANE_SSH_HOST} --dist-dir ${DIST_DIR}"
fi
