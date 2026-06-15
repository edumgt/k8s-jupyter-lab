#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WSL_HOSTS_FILE="/etc/hosts"
WINDOWS_HOSTS_FILE_WIN='C:\Windows\System32\drivers\etc\hosts'

CONTROL_PLANE_HOSTNAME="${CONTROL_PLANE_HOSTNAME:-controller-node}"
WORKER1_HOSTNAME="${WORKER1_HOSTNAME:-w1}"

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-192.168.253.149}"
WORKER1_IP="${WORKER1_IP:-192.168.253.148}"
GATEWAY="${GATEWAY:-192.168.253.1}"
DNS_SERVERS="${DNS_SERVERS:-192.168.253.1,1.1.1.1,8.8.8.8}"
NETWORK_CIDR_PREFIX="${NETWORK_CIDR_PREFIX:-24}"
INGRESS_LB_IP="${INGRESS_LB_IP:-192.168.253.240}"
METALLB_RANGE="${METALLB_RANGE:-192.168.253.240-192.168.253.250}"
NET_INTERFACE="${NET_INTERFACE:-}"
WSL_ROUTE_GATEWAY="${WSL_ROUTE_GATEWAY:-}"

SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-ubuntu}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

HOSTS_DOMAIN_LINE=""
RUN_STAGE_VM_COMMANDS=0
RUN_STAGE_WSL_ROUTE=0
RUN_STAGE_WSL_HOSTS=0
RUN_STAGE_WINDOWS_HOSTS=0
RUN_STAGE_START=0
RUN_STAGE_ALL=0
PRINT_ONLY=0
PAUSE_FOR_VM_SETUP=1
EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: bash init.sh [options] [-- <extra start.sh args>]

init.sh: VMware VM 준비 후 k8s 클러스터 실행 도우미
  1) VM별 static IP/hostname 설정 명령 출력
  2) WSL 라우팅 추가 (192.168.253.0/24 via WSL gateway)
  3) WSL /etc/hosts 업데이트 (ingress 도메인)
  4) Windows hosts 파일 업데이트 (powershell.exe)
  5) start.sh 실행 (SSH 기반 클러스터 검증)

Cluster topology:
  - control-plane: controller-node (192.168.253.149)
  - worker:        w1              (192.168.253.148)
  - apps:          backend, frontend, jupyter

Options:
  --control-plane-ip IP       Default: 192.168.253.149
  --worker1-ip IP             Default: 192.168.253.148
  --gateway IP                Default: 192.168.253.1
  --dns-servers CSV           Default: 192.168.253.1,1.1.1.1,8.8.8.8
  --network-cidr-prefix N     Default: 24
  --net-interface IFACE       Optional net interface for VM static IP script
  --ingress-lb-ip IP          Default: 192.168.253.240
  --metallb-range RANGE       Default: 192.168.253.240-192.168.253.250
  --wsl-hosts-file PATH       Default: /etc/hosts
  --wsl-route-gateway IP      Override WSL route gateway (default: auto-detect)
  --ssh-user USER             SSH user passed to start.sh
  --ssh-password PASS         SSH password passed to start.sh
  --ssh-key-path PATH         SSH key path passed to start.sh
  --ssh-port PORT             SSH port passed to start.sh (default: 22)

Stages:
  --vm-commands               VM별 static IP/hostname 명령 출력
  --apply-wsl-route           WSL 라우팅 추가/교체
  --apply-wsl-hosts           WSL hosts 파일 업데이트
  --apply-windows-hosts       Windows hosts 파일 업데이트 (powershell.exe)
  --run-start                 start.sh 실행
  --all                       vm-commands + WSL route + WSL hosts + Windows hosts + start.sh
  --print-only                변경 없이 수행 내용만 출력
  --pause-for-vm-setup        VM IP 설정 후 start.sh 실행 전 대기 (default)
  --no-pause-for-vm-setup     대기 없이 진행
  -h, --help                  Show this help

Examples:
  bash init.sh --all --ssh-user ubuntu --ssh-password ubuntu
  bash init.sh --vm-commands
  bash init.sh --apply-wsl-route
  bash init.sh --apply-wsl-hosts --apply-windows-hosts
  bash init.sh --run-start --ssh-user ubuntu --ssh-password ubuntu
  bash init.sh --all --no-pause-for-vm-setup -- --skip-node-network-fix
EOF
}

log() {
  printf '[init.sh] %s\n' "$*"
}

die() {
  printf '[init.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

require_ipv4() {
  local label="$1"
  local value="$2"
  is_ipv4 "${value}" || die "${label} must be an IPv4 address: ${value}"
}

build_domain_line() {
  printf '%s %s\n' "${INGRESS_LB_IP}" "dev.platform.local dev-api.platform.local www.platform.local api.platform.local platform.local jupyter.platform.local"
}

discover_wsl_default_gateway() {
  ip route | awk '/^default / {print $3; exit}'
}

print_vm_section() {
  local label="$1"
  local node_ip="$2"
  local node_hostname="$3"

  printf '\n[%s]\n' "${label}"
  printf '%s\n' "sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip ${node_ip} --prefix ${NETWORK_CIDR_PREFIX} --gateway ${GATEWAY} --dns ${DNS_SERVERS}${NET_INTERFACE:+ --iface ${NET_INTERFACE}}"
  printf '%s\n' "sudo bash /opt/k8s-data-platform/scripts/set_hostname_hosts.sh --hostname ${node_hostname} --entry \"${CONTROL_PLANE_IP} ${CONTROL_PLANE_HOSTNAME}\" --entry \"${WORKER1_IP} ${WORKER1_HOSTNAME}\""
  printf '%s\n' "hostname"
  printf '%s\n' "hostname -I"
  printf '%s\n' "ip route"
}

print_vm_commands() {
  log "If imported VMs currently share the same IP, do this first in each VMware console."
  print_vm_section "control-plane VM" "${CONTROL_PLANE_IP}" "${CONTROL_PLANE_HOSTNAME}"
  print_vm_section "worker-1 VM" "${WORKER1_IP}" "${WORKER1_HOSTNAME}"
}

array_has() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done

  return 1
}

pause_for_vm_setup_if_needed() {
  if [[ "${PAUSE_FOR_VM_SETUP}" -ne 1 || "${RUN_STAGE_VM_COMMANDS}" -ne 1 ]]; then
    return 0
  fi
  if [[ "${RUN_STAGE_START}" -ne 1 ]]; then
    return 0
  fi

  if [[ "${PRINT_ONLY}" -eq 1 ]]; then
    log "Would pause for manual VM static-IP/hostname setup before start."
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Pause for VM setup requires interactive stdin. Re-run with --no-pause-for-vm-setup after manual VM IP/hostname changes."
  fi

  log "Pause for VM setup: apply printed static-IP/hostname commands in each VM console first."
  read -r -p "[init.sh] Press Enter after all VMs have unique IP/hostname: "
}

apply_wsl_route() {
  local gateway="$1"
  local target_cidr

  target_cidr="$(printf '%s.0/24' "${CONTROL_PLANE_IP%.*}")"

  if [[ "${PRINT_ONLY}" -eq 1 ]]; then
    log "Would add/replace WSL route: ${target_cidr} via ${gateway} dev eth0"
    return 0
  fi

  sudo ip route replace "${target_cidr}" via "${gateway}" dev eth0
  log "Applied WSL route: ${target_cidr} via ${gateway} dev eth0"
}

upsert_wsl_hosts() {
  local hosts_file="$1"
  local line="$2"

  [[ -f "${hosts_file}" ]] || die "WSL hosts file not found: ${hosts_file}"

  if [[ "${PRINT_ONLY}" -eq 1 ]]; then
    log "Would update WSL hosts file: ${hosts_file}"
    printf '%s\n' "${line}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "${tmp}"' RETURN

  awk '
    /platform\.local|jupyter\.platform\.local/ { next }
    { print }
  ' "${hosts_file}" > "${tmp}"
  printf '%s\n' "${line}" >> "${tmp}"

  if [[ "${EUID}" -eq 0 ]]; then
    cat "${tmp}" > "${hosts_file}"
  else
    sudo cp "${tmp}" "${hosts_file}"
  fi
  log "Updated WSL hosts file: ${hosts_file}"
}

apply_windows_hosts() {
  local line="$1"
  local escaped_line

  command -v powershell.exe >/dev/null 2>&1 || die "powershell.exe is required to update Windows hosts from WSL."

  escaped_line="${line//\'/''}"

  if [[ "${PRINT_ONLY}" -eq 1 ]]; then
    log "Would update Windows hosts file: ${WINDOWS_HOSTS_FILE_WIN}"
    printf '%s\n' "${line}"
    return 0
  fi

  powershell.exe -NoProfile -Command "
    \$hostsPath = '${WINDOWS_HOSTS_FILE_WIN}';
    \$newLine = '${escaped_line}';
    \$content = @();
    if (Test-Path -LiteralPath \$hostsPath) {
      \$content = Get-Content -LiteralPath \$hostsPath | Where-Object {
        \$_ -notmatch 'platform\.local|jupyter\.platform\.local'
      }
    }
    \$content += \$newLine
    Set-Content -LiteralPath \$hostsPath -Value \$content -Encoding ASCII
  " >/dev/null

  log "Updated Windows hosts file: ${WINDOWS_HOSTS_FILE_WIN}"
}

run_start() {
  local cmd=(
    bash "${ROOT_DIR}/start.sh"
    --control-plane-ip "${CONTROL_PLANE_IP}"
    --worker1-ip "${WORKER1_IP}"
    --gateway "${GATEWAY}"
    --dns-servers "${DNS_SERVERS}"
    --metallb-range "${METALLB_RANGE}"
    --ingress-lb-ip "${INGRESS_LB_IP}"
  )

  if [[ -n "${NET_INTERFACE}" ]]; then
    cmd+=(--net-interface "${NET_INTERFACE}")
  fi
  if [[ -n "${SSH_USER}" ]]; then
    cmd+=(--ssh-user "${SSH_USER}")
  fi
  if [[ -n "${SSH_PASSWORD}" ]]; then
    cmd+=(--ssh-password "${SSH_PASSWORD}")
  fi
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    cmd+=(--ssh-key-path "${SSH_KEY_PATH}")
  fi
  if [[ "${SSH_PORT}" != "22" ]]; then
    cmd+=(--ssh-port "${SSH_PORT}")
  fi
  if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    cmd+=("${EXTRA_ARGS[@]}")
  fi

  if [[ "${PRINT_ONLY}" -eq 1 ]]; then
    log "Would run start.sh with:"
    printf '%q ' "${cmd[@]}"
    printf '\n'
    return 0
  fi

  exec "${cmd[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --dns-servers)
      [[ $# -ge 2 ]] || die "--dns-servers requires a value"
      DNS_SERVERS="$2"
      shift 2
      ;;
    --network-cidr-prefix)
      [[ $# -ge 2 ]] || die "--network-cidr-prefix requires a value"
      NETWORK_CIDR_PREFIX="$2"
      shift 2
      ;;
    --net-interface)
      [[ $# -ge 2 ]] || die "--net-interface requires a value"
      NET_INTERFACE="$2"
      shift 2
      ;;
    --ingress-lb-ip)
      [[ $# -ge 2 ]] || die "--ingress-lb-ip requires a value"
      INGRESS_LB_IP="$2"
      shift 2
      ;;
    --metallb-range)
      [[ $# -ge 2 ]] || die "--metallb-range requires a value"
      METALLB_RANGE="$2"
      shift 2
      ;;
    --wsl-hosts-file)
      [[ $# -ge 2 ]] || die "--wsl-hosts-file requires a value"
      WSL_HOSTS_FILE="$2"
      shift 2
      ;;
    --wsl-route-gateway)
      [[ $# -ge 2 ]] || die "--wsl-route-gateway requires a value"
      WSL_ROUTE_GATEWAY="$2"
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
    --pause-for-vm-setup)
      PAUSE_FOR_VM_SETUP=1
      shift
      ;;
    --no-pause-for-vm-setup)
      PAUSE_FOR_VM_SETUP=0
      shift
      ;;
    --vm-commands)
      RUN_STAGE_VM_COMMANDS=1
      shift
      ;;
    --apply-wsl-route)
      RUN_STAGE_WSL_ROUTE=1
      shift
      ;;
    --apply-wsl-hosts)
      RUN_STAGE_WSL_HOSTS=1
      shift
      ;;
    --apply-windows-hosts)
      RUN_STAGE_WINDOWS_HOSTS=1
      shift
      ;;
    --run-start)
      RUN_STAGE_START=1
      shift
      ;;
    --all)
      RUN_STAGE_ALL=1
      shift
      ;;
    --print-only)
      PRINT_ONLY=1
      shift
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${RUN_STAGE_ALL}" -eq 1 ]]; then
  RUN_STAGE_VM_COMMANDS=1
  RUN_STAGE_WSL_ROUTE=1
  RUN_STAGE_WSL_HOSTS=1
  RUN_STAGE_WINDOWS_HOSTS=1
  RUN_STAGE_START=1
fi

require_ipv4 "control-plane IP" "${CONTROL_PLANE_IP}"
require_ipv4 "worker1 IP" "${WORKER1_IP}"
require_ipv4 "gateway" "${GATEWAY}"
require_ipv4 "ingress LB IP" "${INGRESS_LB_IP}"

if [[ -z "${WSL_ROUTE_GATEWAY}" ]]; then
  WSL_ROUTE_GATEWAY="$(discover_wsl_default_gateway)"
fi
[[ -n "${WSL_ROUTE_GATEWAY}" ]] || die "Unable to detect WSL default gateway. Pass --wsl-route-gateway."
require_ipv4 "WSL route gateway" "${WSL_ROUTE_GATEWAY}"

HOSTS_DOMAIN_LINE="$(build_domain_line)"

if [[ "${RUN_STAGE_VM_COMMANDS}" -eq 0 && "${RUN_STAGE_WSL_ROUTE}" -eq 0 && "${RUN_STAGE_WSL_HOSTS}" -eq 0 && "${RUN_STAGE_WINDOWS_HOSTS}" -eq 0 && "${RUN_STAGE_START}" -eq 0 ]]; then
  log "No stage option provided. Defaulting to --vm-commands."
  RUN_STAGE_VM_COMMANDS=1
fi

log "Planned node IPs"
log "  ${CONTROL_PLANE_HOSTNAME} -> ${CONTROL_PLANE_IP}"
log "  ${WORKER1_HOSTNAME} -> ${WORKER1_IP}"
log "WSL route gateway -> ${WSL_ROUTE_GATEWAY}"
log "Ingress domains -> ${HOSTS_DOMAIN_LINE}"

if [[ "${RUN_STAGE_VM_COMMANDS}" -eq 1 ]]; then
  print_vm_commands
fi

pause_for_vm_setup_if_needed

if [[ "${RUN_STAGE_WSL_ROUTE}" -eq 1 ]]; then
  apply_wsl_route "${WSL_ROUTE_GATEWAY}"
fi

if [[ "${RUN_STAGE_WSL_HOSTS}" -eq 1 ]]; then
  upsert_wsl_hosts "${WSL_HOSTS_FILE}" "${HOSTS_DOMAIN_LINE}"
fi

if [[ "${RUN_STAGE_WINDOWS_HOSTS}" -eq 1 ]]; then
  apply_windows_hosts "${HOSTS_DOMAIN_LINE}"
fi

if [[ "${RUN_STAGE_START}" -eq 1 ]]; then
  run_start
fi
