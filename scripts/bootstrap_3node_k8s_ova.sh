#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE=""

usage() {
  cat <<'EOF'
Usage: bash scripts/bootstrap_3node_k8s_ova.sh --config <env-file>

This script configures a Kubernetes layout automatically:
  control-plane (k8s-data-platform)
  worker-1 (k8s-worker-1)
  worker-2 (k8s-worker-2)
  worker-3 (k8s-worker-3, optional)

Features:
  1) Static IP/netplan setup for all nodes
  2) Hostname + /etc/hosts alignment
  3) kubeadm join for worker nodes
  4) Optional overlay apply for GitLab + Nexus placement
  5) Optional NGINX Ingress + MetalLB setup for URL-based access

Required:
  - SSH access to all nodes
  - control-plane already initialized by kubeadm
  - config file based on scripts/templates/3node-cluster.env.example

Options:
  --config FILE   Path to env config file
  -h, --help      Show this help
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

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a value"
      CONFIG_FILE="$2"
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

[[ -n "${CONFIG_FILE}" ]] || die "Provide --config <env-file>."
[[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"

CONTROL_PLANE_SSH_HOST="${CONTROL_PLANE_SSH_HOST:-}"
CONTROL_PLANE_HOSTNAME="${CONTROL_PLANE_HOSTNAME:-k8s-data-platform}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"

WORKER1_SSH_HOST="${WORKER1_SSH_HOST:-}"
WORKER1_HOSTNAME="${WORKER1_HOSTNAME:-k8s-worker-1}"
WORKER1_IP="${WORKER1_IP:-}"

WORKER2_SSH_HOST="${WORKER2_SSH_HOST:-}"
WORKER2_HOSTNAME="${WORKER2_HOSTNAME:-k8s-worker-2}"
WORKER2_IP="${WORKER2_IP:-}"

WORKER3_SSH_HOST="${WORKER3_SSH_HOST:-}"
WORKER3_HOSTNAME="${WORKER3_HOSTNAME:-k8s-worker-3}"
WORKER3_IP="${WORKER3_IP:-}"

NETWORK_CIDR_PREFIX="${NETWORK_CIDR_PREFIX:-24}"
GATEWAY="${GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-}"
NET_INTERFACE="${NET_INTERFACE:-}"

TOKEN_TTL="${TOKEN_TTL:-2h}"
SKIP_NETWORK="${SKIP_NETWORK:-0}"
SKIP_JOIN="${SKIP_JOIN:-0}"
APPLY_OVERLAY="${APPLY_OVERLAY:-1}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
OVERLAY="${OVERLAY:-dev-3node}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"
SETUP_INGRESS_STACK="${SETUP_INGRESS_STACK:-1}"
METALLB_ADDRESS_RANGE="${METALLB_ADDRESS_RANGE:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
METALLB_MANIFEST="${METALLB_MANIFEST:-}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-}"

[[ -n "${CONTROL_PLANE_SSH_HOST}" ]] || die "CONTROL_PLANE_SSH_HOST is required."
[[ -n "${CONTROL_PLANE_IP}" ]] || die "CONTROL_PLANE_IP is required."
[[ -n "${WORKER1_SSH_HOST}" ]] || die "WORKER1_SSH_HOST is required."
[[ -n "${WORKER1_IP}" ]] || die "WORKER1_IP is required."
[[ -n "${WORKER2_SSH_HOST}" ]] || die "WORKER2_SSH_HOST is required."
[[ -n "${WORKER2_IP}" ]] || die "WORKER2_IP is required."

ENABLE_WORKER3=0
if [[ -n "${WORKER3_SSH_HOST}" || -n "${WORKER3_IP}" ]]; then
  [[ -n "${WORKER3_SSH_HOST}" ]] || die "WORKER3_SSH_HOST is required when WORKER3_IP is set."
  [[ -n "${WORKER3_IP}" ]] || die "WORKER3_IP is required when WORKER3_SSH_HOST is set."
  ENABLE_WORKER3=1
fi

if ! is_true "${SKIP_NETWORK}"; then
  [[ -n "${GATEWAY}" ]] || die "GATEWAY is required unless SKIP_NETWORK=1."
  if [[ -z "${DNS_SERVERS}" ]]; then
    DNS_SERVERS="${GATEWAY},1.1.1.1,8.8.8.8"
    log "DNS_SERVERS is empty. Using gateway-first default: ${DNS_SERVERS}"
  fi
fi

require_command ssh
require_command scp
require_command base64
require_command awk

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

if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

ssh_run() {
  local host="$1"
  shift

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
    return
  fi

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
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

ssh_run_sudo() {
  local host="$1"
  local command="$2"
  local escaped_pw
  local escaped_command

  escaped_command="$(escape_single_quotes "${command}")"
  if [[ -n "${SSH_PASSWORD}" ]]; then
    escaped_pw="$(escape_single_quotes "${SSH_PASSWORD}")"
    ssh_run "${host}" "printf '%s\n' '${escaped_pw}' | sudo -S -p '' bash -lc '${escaped_command}'"
    return
  fi

  ssh_run "${host}" "sudo bash -lc '${escaped_command}'"
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

  die "Timed out waiting for SSH (${label}): ${host}"
}

default_ingress_values() {
  local prefix
  prefix="$(printf '%s' "${CONTROL_PLANE_IP}" | awk -F '.' 'NF == 4 { print $1 "." $2 "." $3 }')"
  [[ -n "${prefix}" ]] || die "Unable to derive /24 prefix from CONTROL_PLANE_IP=${CONTROL_PLANE_IP}"

  if [[ -z "${METALLB_ADDRESS_RANGE}" ]]; then
    METALLB_ADDRESS_RANGE="${prefix}.240-${prefix}.250"
  fi

  if [[ -z "${INGRESS_LB_IP}" ]]; then
    INGRESS_LB_IP="${prefix}.240"
  fi
}

HOSTS_BLOCK="${CONTROL_PLANE_IP} ${CONTROL_PLANE_HOSTNAME}"$'\n'"${WORKER1_IP} ${WORKER1_HOSTNAME}"$'\n'"${WORKER2_IP} ${WORKER2_HOSTNAME}"
if [[ "${ENABLE_WORKER3}" -eq 1 ]]; then
  HOSTS_BLOCK="${HOSTS_BLOCK}"$'\n'"${WORKER3_IP} ${WORKER3_HOSTNAME}"
fi
HOSTS_B64="$(printf '%s\n' "${HOSTS_BLOCK}" | base64 -w 0)"

configure_node_network() {
  local bootstrap_host="$1"
  local final_ip="$2"
  local target_hostname="$3"

  log "Configuring static IP/hostname on ${target_hostname} via ${bootstrap_host}"
  if ! ssh_run_sudo "${bootstrap_host}" "bash -s -- '$target_hostname' '$final_ip' '$NETWORK_CIDR_PREFIX' '$GATEWAY' '$DNS_SERVERS' '$NET_INTERFACE' '$HOSTS_B64'" <<'REMOTE_NET'; then
set -euo pipefail

TARGET_HOSTNAME="$1"
TARGET_IP="$2"
PREFIX="$3"
TARGET_GATEWAY="$4"
DNS_CSV="$5"
FORCED_IFACE="$6"
HOSTS_B64="$7"

IFACE="${FORCED_IFACE}"
if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip -4 route ls default | awk '{print $5; exit}')"
fi
[[ -n "${IFACE}" ]] || { echo "Unable to detect network interface"; exit 1; }

DNS_LINES=""
IFS=',' read -r -a DNS_ITEMS <<< "${DNS_CSV}"
for item in "${DNS_ITEMS[@]}"; do
  item="${item// /}"
  [[ -n "${item}" ]] || continue
  DNS_LINES="${DNS_LINES}        - ${item}"$'\n'
done
if [[ -z "${DNS_LINES}" ]]; then
  DNS_LINES="        - 1.1.1.1"$'\n'"        - 8.8.8.8"$'\n'
fi

{
  echo "network:"
  echo "  version: 2"
  echo "  renderer: networkd"
  echo "  ethernets:"
  echo "    ${IFACE}:"
  echo "      dhcp4: false"
  echo "      addresses:"
  echo "        - ${TARGET_IP}/${PREFIX}"
  echo "      routes:"
  echo "        - to: default"
  echo "          via: ${TARGET_GATEWAY}"
  echo "      nameservers:"
  echo "        addresses:"
  printf '%s' "${DNS_LINES}"
} >/etc/netplan/99-k8s-data-platform-static.yaml

hostnamectl set-hostname "${TARGET_HOSTNAME}"

HOSTS_BLOCK="$(printf '%s' "${HOSTS_B64}" | base64 -d)"
TMP_HOSTS="$(mktemp)"
cp /etc/hosts "${TMP_HOSTS}"
sed -i '/# BEGIN K8S-DP-NODES/,/# END K8S-DP-NODES/d' "${TMP_HOSTS}"
{
  echo "# BEGIN K8S-DP-NODES"
  printf '%s\n' "${HOSTS_BLOCK}"
  echo "# END K8S-DP-NODES"
} >>"${TMP_HOSTS}"
cat "${TMP_HOSTS}" >/etc/hosts
rm -f "${TMP_HOSTS}"

netplan generate
netplan apply
REMOTE_NET
    log "SSH disconnected while applying network on ${target_hostname}; retrying via final IP"
  fi

  wait_for_ssh "${final_ip}" "${target_hostname}"
}

prepare_remote_join_script() {
  local host="$1"
  local remote_script="/tmp/join_worker_node.sh"
  local local_script

  local_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/join_worker_node.sh"
  scp_copy "${local_script}" "${host}" "${remote_script}"
  ssh_run "${host}" "chmod +x '${remote_script}'"
}

join_worker_node() {
  local worker_ip="$1"
  local worker_hostname="$2"
  local join_command_b64="$3"

  log "Joining ${worker_hostname} to control-plane"
  prepare_remote_join_script "${worker_ip}"
  ssh_run_sudo "${worker_ip}" "/tmp/join_worker_node.sh --hostname '${worker_hostname}' --join-command-b64 '${join_command_b64}'"
}

node_exists_on_control_plane() {
  local node_name="$1"
  ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get node '${node_name}' >/dev/null 2>&1"
}

node_ready_on_control_plane() {
  local node_name="$1"
  local ready_status

  ready_status="$(
    ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get node '${node_name}' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" \
      2>/dev/null || true
  )"
  [[ "${ready_status}" == "True" ]]
}

ensure_worker_joined() {
  local worker_ip="$1"
  local worker_hostname="$2"
  local join_command_b64="$3"

  if node_exists_on_control_plane "${worker_hostname}"; then
    if node_ready_on_control_plane "${worker_hostname}"; then
      log "Node ${worker_hostname} is already Ready; skipping kubeadm join"
      return 0
    fi
    log "Node ${worker_hostname} exists but is not Ready; deleting stale node object before rejoin"
    ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node '${worker_hostname}' --ignore-not-found"
  fi

  join_worker_node "${worker_ip}" "${worker_hostname}" "${join_command_b64}"
}

log "Checking SSH connectivity"
wait_for_ssh "${CONTROL_PLANE_SSH_HOST}" "control-plane bootstrap"
wait_for_ssh "${WORKER1_SSH_HOST}" "worker1 bootstrap"
wait_for_ssh "${WORKER2_SSH_HOST}" "worker2 bootstrap"
if [[ "${ENABLE_WORKER3}" -eq 1 ]]; then
  wait_for_ssh "${WORKER3_SSH_HOST}" "worker3 bootstrap"
fi

if ! is_true "${SKIP_NETWORK}"; then
  configure_node_network "${CONTROL_PLANE_SSH_HOST}" "${CONTROL_PLANE_IP}" "${CONTROL_PLANE_HOSTNAME}"
  configure_node_network "${WORKER1_SSH_HOST}" "${WORKER1_IP}" "${WORKER1_HOSTNAME}"
  configure_node_network "${WORKER2_SSH_HOST}" "${WORKER2_IP}" "${WORKER2_HOSTNAME}"
  if [[ "${ENABLE_WORKER3}" -eq 1 ]]; then
    configure_node_network "${WORKER3_SSH_HOST}" "${WORKER3_IP}" "${WORKER3_HOSTNAME}"
  fi
fi

if ! is_true "${SKIP_JOIN}"; then
  log "Generating kubeadm join command from control-plane"
  JOIN_COMMAND="$(ssh_run_sudo "${CONTROL_PLANE_IP}" "kubeadm token create --ttl '${TOKEN_TTL}' --print-join-command" | tr -d '\r' | tail -n 1)"
  [[ -n "${JOIN_COMMAND}" ]] || die "Failed to generate kubeadm join command."
  JOIN_COMMAND_B64="$(printf '%s' "${JOIN_COMMAND}" | base64 -w 0)"

  ensure_worker_joined "${WORKER1_IP}" "${WORKER1_HOSTNAME}" "${JOIN_COMMAND_B64}"
  ensure_worker_joined "${WORKER2_IP}" "${WORKER2_HOSTNAME}" "${JOIN_COMMAND_B64}"
  if [[ "${ENABLE_WORKER3}" -eq 1 ]]; then
    ensure_worker_joined "${WORKER3_IP}" "${WORKER3_HOSTNAME}" "${JOIN_COMMAND_B64}"
  fi

  log "Waiting for worker nodes to become Ready"
  ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready node/${WORKER1_HOSTNAME} --timeout=420s"
  ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready node/${WORKER2_HOSTNAME} --timeout=420s"
  if [[ "${ENABLE_WORKER3}" -eq 1 ]]; then
    ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl wait --for=condition=Ready node/${WORKER3_HOSTNAME} --timeout=420s"
  fi
fi

if is_true "${APPLY_OVERLAY}"; then
  OVERLAY_WORKERS="${WORKER1_HOSTNAME},${WORKER2_HOSTNAME}"
  if [[ "${ENABLE_WORKER3}" -eq 1 ]]; then
    OVERLAY_WORKERS="${OVERLAY_WORKERS},${WORKER3_HOSTNAME}"
  fi
  log "Applying overlay (${OVERLAY}) with workers=${OVERLAY_WORKERS}"
  ssh_run_sudo "${CONTROL_PLANE_IP}" "if [[ -f '${REMOTE_REPO_ROOT}/scripts/configure_multinode_cluster.sh' ]]; then bash '${REMOTE_REPO_ROOT}/scripts/configure_multinode_cluster.sh' --env '${ENVIRONMENT}' --overlay '${OVERLAY}' --workers '${OVERLAY_WORKERS}'; else echo 'Missing remote script: ${REMOTE_REPO_ROOT}/scripts/configure_multinode_cluster.sh' >&2; exit 1; fi"
fi

if is_true "${SETUP_INGRESS_STACK}"; then
  default_ingress_values
  log "Configuring ingress-nginx + MetalLB (range=${METALLB_ADDRESS_RANGE}, lb_ip=${INGRESS_LB_IP})"
  if ssh_run_sudo "${CONTROL_PLANE_IP}" "test -f '${REMOTE_REPO_ROOT}/scripts/setup_ingress_metallb.sh'"; then
    REMOTE_INGRESS_CMD="bash '${REMOTE_REPO_ROOT}/scripts/setup_ingress_metallb.sh' --metallb-range '${METALLB_ADDRESS_RANGE}' --ingress-lb-ip '${INGRESS_LB_IP}'"
    if [[ -n "${METALLB_MANIFEST}" ]]; then
      REMOTE_INGRESS_CMD="${REMOTE_INGRESS_CMD} --metallb-manifest '${METALLB_MANIFEST}'"
    fi
    if [[ -n "${INGRESS_MANIFEST}" ]]; then
      REMOTE_INGRESS_CMD="${REMOTE_INGRESS_CMD} --ingress-manifest '${INGRESS_MANIFEST}'"
    fi
    ssh_run_sudo "${CONTROL_PLANE_IP}" "${REMOTE_INGRESS_CMD}"
  else
    log "Ingress setup script is missing on control-plane (${REMOTE_REPO_ROOT}/scripts/setup_ingress_metallb.sh); skipping ingress/metallb setup."
  fi
fi

log "Final node status"
ssh_run_sudo "${CONTROL_PLANE_IP}" "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide"

log "Bootstrap completed."
if is_true "${SETUP_INGRESS_STACK}"; then
  log "Access endpoints (Ingress URL):"
  if [[ "${ENVIRONMENT}" == "dev" ]]; then
    log "  Frontend : http://dev.platform.local"
    log "  Backend  : http://dev-api.platform.local/docs"
  else
    log "  Frontend : http://www.platform.local"
    log "  Backend  : http://api.platform.local/docs"
  fi
  log "  Jupyter  : http://jupyter.platform.local/lab"
  log "  GitLab   : http://gitlab.platform.local"
  log "  Airflow  : http://airflow.platform.local"
  log "  Nexus    : http://nexus.platform.local"
  log "Hosts file example:"
  log "  ${INGRESS_LB_IP} dev.platform.local"
  log "  ${INGRESS_LB_IP} dev-api.platform.local"
  log "  ${INGRESS_LB_IP} www.platform.local"
  log "  ${INGRESS_LB_IP} api.platform.local"
  log "  ${INGRESS_LB_IP} platform.local"
  log "  ${INGRESS_LB_IP} jupyter.platform.local"
  log "  ${INGRESS_LB_IP} gitlab.platform.local"
  log "  ${INGRESS_LB_IP} airflow.platform.local"
  log "  ${INGRESS_LB_IP} nexus.platform.local"
else
  log "Access endpoints (legacy NodePort):"
  log "  Frontend : http://${CONTROL_PLANE_IP}:30080"
  log "  Backend  : http://${CONTROL_PLANE_IP}:30081"
  log "  GitLab   : http://${CONTROL_PLANE_IP}:30089"
  log "  Nexus    : http://${CONTROL_PLANE_IP}:30091"
fi
