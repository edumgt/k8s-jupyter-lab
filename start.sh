#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-controller-node}"
WORKER1_NAME="${WORKER1_NAME:-w1}"

ENVIRONMENT="${ENVIRONMENT:-dev}"
OVERLAY="${OVERLAY:-dev-1node}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.253.149}"
WORKER1_IP="${WORKER1_IP:-192.168.253.148}"
GATEWAY="${GATEWAY:-192.168.253.1}"
NETWORK_CIDR_PREFIX="${NETWORK_CIDR_PREFIX:-24}"
DNS_SERVERS="${DNS_SERVERS:-}"
NET_INTERFACE="${NET_INTERFACE:-}"

METALLB_ADDRESS_RANGE="${METALLB_ADDRESS_RANGE:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
SETUP_INGRESS_STACK=1

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

SKIP_NODE_NETWORK_FIX=0

NAMESPACE=""
CONTROL_PLANE_SSH_HOST=""
WORKER1_SSH_HOST=""

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

SSH 기반 Kubernetes 클러스터 검증 (control-plane + worker1):
  1) 노드 런타임 수정 (kubelet:10250 / DNS 타임아웃)
  2) 노드/파드/PVC/노드 배치 검증 (backend, frontend, jupyter)
  3) HTTP 엔드포인트 점검 (verify.sh)

Options:
  --control-plane-name NAME    Default: controller-node
  --worker1-name NAME          Default: w1

  --env dev|prod               Default: dev
  --overlay NAME               Default: dev-1node
  --remote-repo-root PATH      Default: /opt/k8s-data-platform

  --control-plane-ip IP        Default: 192.168.253.149
  --worker1-ip IP              Default: 192.168.253.148
  --gateway IP                 Default: 192.168.253.1
  --network-cidr-prefix N      Default: 24
  --dns-servers CSV            Default: <gateway>,1.1.1.1,8.8.8.8
  --net-interface IFACE        Optional net interface override

  --metallb-range RANGE        Example: 192.168.253.240-192.168.253.250
  --ingress-lb-ip IP           Example: 192.168.253.240
  --skip-ingress-setup         Skip ingress/metallb 점검

  --skip-node-network-fix      Skip kubelet(:10250)/DNS 타임아웃 수정

  --ssh-user USER              SSH user (required)
  --ssh-password PASS          SSH password
  --ssh-key-path PATH          SSH key path
  --ssh-port PORT              Default: 22

  -h, --help                   Show this help

Examples:
  bash start.sh \
    --control-plane-ip 192.168.253.149 \
    --worker1-ip 192.168.253.148 \
    --gateway 192.168.253.1 \
    --metallb-range 192.168.253.240-192.168.253.250 \
    --ingress-lb-ip 192.168.253.240 \
    --ssh-user ubuntu --ssh-password ubuntu
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
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

apply_node_runtime_fixes() {
  local fix_script_local="${ROOT_DIR}/scripts/fix_kubelet_network_timeouts.sh"
  local fix_script_remote="/tmp/fix_kubelet_network_timeouts.sh"
  local entry
  local label
  local host
  declare -A seen_hosts=()

  [[ -f "${fix_script_local}" ]] || die "Missing node fix script: ${fix_script_local}"

  for entry in \
    "control-plane:${CONTROL_PLANE_SSH_HOST}" \
    "worker-1:${WORKER1_SSH_HOST}"; do
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
  ssh_run "${host}" "kubectl $*"
}

deploy_k8s_app() {
  local host="$1"
  local overlay_path="${ROOT_DIR}/infra/k8s/overlays/${OVERLAY}"

  [[ -d "${overlay_path}" ]] || die "Overlay directory not found: ${overlay_path}"
  require_command kubectl

  if ssh_run "${host}" "kubectl get ns '${NAMESPACE}' >/dev/null 2>&1"; then
    log "Cleaning up unused apps from ${NAMESPACE}"
    ssh_run "${host}" "kubectl delete deploy,svc,statefulset gitlab nexus airflow mongodb redis -n '${NAMESPACE}' --ignore-not-found=true 2>/dev/null || true"
    ssh_run "${host}" "kubectl delete svc gitlab-web -n '${NAMESPACE}' --ignore-not-found=true 2>/dev/null || true"
    ssh_run "${host}" "kubectl delete pvc gitlab-config gitlab-logs gitlab-data nexus-data -n '${NAMESPACE}' --ignore-not-found=true 2>/dev/null || true"
    ssh_run "${host}" "kubectl delete serviceaccount airflow -n '${NAMESPACE}' --ignore-not-found=true 2>/dev/null || true"
    ssh_run "${host}" "kubectl delete clusterrole,clusterrolebinding airflow-control-plane-reader airflow --ignore-not-found=true 2>/dev/null || true"
  fi

  log "Releasing NodePorts 30080/30081/30088 across all namespaces"
  ssh_run "${host}" "kubectl get svc --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {range .spec.ports[*]}{.nodePort} {end}{\"\n\"}{end}' 2>/dev/null | while read ns name ports; do for p in \$ports; do case \"\$p\" in 30080|30081|30088) kubectl delete svc \"\$name\" -n \"\$ns\" --ignore-not-found=true 2>/dev/null; break;; esac; done; done"
  sleep 3

  log "Applying kustomize overlay: ${OVERLAY}"
  if [[ -n "${SSH_PASSWORD}" ]]; then
    kubectl kustomize "${overlay_path}" | \
      SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        "kubectl apply -f -"
  else
    kubectl kustomize "${overlay_path}" | \
      ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        "kubectl apply -f -"
  fi
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
      ssh_capture "${host}" "kubectl -n ingress-nginx get svc ingress-nginx-controller -o custom-columns=IP:.status.loadBalancer.ingress[0].ip --no-headers 2>/dev/null | tr -d '[:space:]'" \
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
  local frontend_nodes

  backend_node="$(ssh_capture "${host}" "kubectl -n '${NAMESPACE}' get pods -l app=backend -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${backend_node}" ]] || die "backend pod node 확인 실패"
  [[ "${backend_node}" == "${WORKER1_NAME}" ]] || die "backend expected on ${WORKER1_NAME}, got ${backend_node}"

  jupyter_node="$(ssh_capture "${host}" "kubectl -n '${NAMESPACE}' get pods -l app=jupyter -o custom-columns=NODE:.spec.nodeName --no-headers | head -n 1 | tr -d '[:space:]'")"
  [[ -n "${jupyter_node}" ]] || die "jupyter pod node 확인 실패"
  [[ "${jupyter_node}" == "${WORKER1_NAME}" ]] || die "jupyter expected on ${WORKER1_NAME}, got ${jupyter_node}"

  frontend_nodes="$(ssh_capture "${host}" "kubectl -n '${NAMESPACE}' get pods -l app=frontend -o custom-columns=NODE:.spec.nodeName --no-headers | sed '/^$/d'")"
  [[ -n "${frontend_nodes}" ]] || die "frontend pod node 확인 실패"

  if printf '%s\n' "${frontend_nodes}" | grep -Fxq "${CONTROL_PLANE_NAME}"; then
    die "frontend pod must not be scheduled on control-plane (${CONTROL_PLANE_NAME})"
  fi
  if ! printf '%s\n' "${frontend_nodes}" | grep -Fxq "${WORKER1_NAME}"; then
    die "frontend pod가 worker 노드(${WORKER1_NAME})에 스케줄되지 않았습니다."
  fi
}

validate_cluster_state() {
  local host="$1"
  local not_ready_pods
  local unbound_pvc

  remote_kubectl "${host}" "wait --for=condition=Ready node/${CONTROL_PLANE_NAME} --timeout=420s"
  remote_kubectl "${host}" "wait --for=condition=Ready node/${WORKER1_NAME} --timeout=420s"

  for deploy in backend frontend jupyter; do
    remote_kubectl "${host}" "-n ${NAMESPACE} wait --for=condition=Available deployment/${deploy} --timeout=900s"
  done

  not_ready_pods="$(
    ssh_capture "${host}" "kubectl -n '${NAMESPACE}' get pods --no-headers | awk '\$3 != \"Running\" && \$3 != \"Completed\" { print \$1 \" \" \$3 }'" || true
  )"
  if [[ -n "${not_ready_pods}" ]]; then
    printf '%s\n' "${not_ready_pods}"
    die "Not-ready pods detected in namespace ${NAMESPACE}."
  fi

  unbound_pvc="$(
    ssh_capture "${host}" "kubectl -n '${NAMESPACE}' get pvc --no-headers | awk '\$2 != \"Bound\" { print \$1 \" \" \$2 }'" || true
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

while [[ $# -gt 0 ]]; do
  case "$1" in
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
require_command awk
require_command ssh

[[ -n "${CONTROL_PLANE_IP}" ]] || die "--control-plane-ip is required"
[[ -n "${WORKER1_IP}" ]] || die "--worker1-ip is required"

if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="${GATEWAY},1.1.1.1,8.8.8.8"
fi

if [[ -n "${SSH_KEY_PATH}" ]]; then
  [[ -f "${SSH_KEY_PATH}" ]] || die "SSH key path not found: ${SSH_KEY_PATH}"
fi

if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
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

if [[ "${CONTROL_PLANE_NAME}" == "${WORKER1_NAME}" ]]; then
  die "VM names must be unique."
fi

NAMESPACE="data-platform-${ENVIRONMENT}"
CONTROL_PLANE_SSH_HOST="${CONTROL_PLANE_IP}"
WORKER1_SSH_HOST="${WORKER1_IP}"

TOTAL_STEPS=3
if [[ "${SKIP_NODE_NETWORK_FIX}" -eq 0 ]]; then
  TOTAL_STEPS=$(( TOTAL_STEPS + 1 ))
fi
STEP_INDEX=1

log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Wait for SSH connectivity"
wait_for_ssh "${CONTROL_PLANE_SSH_HOST}" "control-plane"
wait_for_ssh "${WORKER1_SSH_HOST}" "worker1"

STEP_INDEX=$(( STEP_INDEX + 1 ))
if [[ "${SKIP_NODE_NETWORK_FIX}" -eq 0 ]]; then
  log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Fix kubelet(:10250) and DNS timeout settings"
  apply_node_runtime_fixes
  STEP_INDEX=$(( STEP_INDEX + 1 ))
fi

log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Deploy k8s manifests (overlay: ${OVERLAY})"
deploy_k8s_app "${CONTROL_PLANE_SSH_HOST}"

STEP_INDEX=$(( STEP_INDEX + 1 ))
log "Step ${STEP_INDEX}/${TOTAL_STEPS}: Validate cluster placement and HTTP endpoints"
validate_cluster_state "${CONTROL_PLANE_SSH_HOST}"
verify_http_endpoints "${CONTROL_PLANE_SSH_HOST}"

log "Completed."
log "Control-plane SSH host: ${CONTROL_PLANE_SSH_HOST}"
if [[ "${SETUP_INGRESS_STACK}" -eq 1 ]]; then
  log "Ingress URL: http://platform.local"
  log "Hosts example:"
  if [[ -n "${RESOLVED_INGRESS_LB_IP:-}" ]]; then
    log "  ${RESOLVED_INGRESS_LB_IP} platform.local jupyter.platform.local"
  else
    log "  <INGRESS_LB_IP> platform.local jupyter.platform.local"
  fi
fi
