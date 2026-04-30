#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-data-platform}"
WORKER1_NAME="${WORKER1_NAME:-k8s-worker-1}"
WORKER2_NAME="${WORKER2_NAME:-k8s-worker-2}"
WORKER3_NAME="${WORKER3_NAME:-k8s-worker-3}"

POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
VMRUN_WIN="${VMRUN_WIN:-C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe}"
VMWARE_EXE_WIN="${VMWARE_EXE_WIN:-}"

SKIP_BUILD=0
FORCE_BUILD=0
FORCE_RECREATE_WORKERS=0
SKIP_BOOTSTRAP=0
STATIC_NETWORK=0
APPLY_OVERLAY=1
REGISTER_IN_WORKSTATION=1
VM_START_MODE="${VM_START_MODE:-nogui}"

CONTROL_PLANE_IP=""
WORKER1_IP=""
WORKER2_IP=""
WORKER3_IP=""
GATEWAY=""
NETWORK_CIDR_PREFIX="${NETWORK_CIDR_PREFIX:-24}"
DNS_SERVERS="${DNS_SERVERS:-}"
NET_INTERFACE="${NET_INTERFACE:-}"

SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

TOKEN_TTL="${TOKEN_TTL:-2h}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
OVERLAY="${OVERLAY:-dev-3node}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"
SETUP_INGRESS_STACK="${SETUP_INGRESS_STACK:-1}"
METALLB_ADDRESS_RANGE="${METALLB_ADDRESS_RANGE:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
METALLB_MANIFEST="${METALLB_MANIFEST:-}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-}"

WAIT_IP_TIMEOUT_SEC="${WAIT_IP_TIMEOUT_SEC:-600}"
RUNTIME_DIR=""

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/vmware_provision_3node.sh [options]

One-shot VMware flow (control-plane + worker-1/2/3):
  1) Build control-plane VM with Packer (vmware-iso)
  2) Clone worker-1 / worker-2 / worker-3 from control-plane VMX
  3) Start all VMs
  4) Auto-run bootstrap_3node_k8s_ova.sh (join + overlay + ingress/metallb)

Options:
  --vars-file PATH          Packer var file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --control-plane-name NAME Control-plane VM/hostname (default: k8s-data-platform)
  --worker1-name NAME       Worker-1 VM/hostname (default: k8s-worker-1)
  --worker2-name NAME       Worker-2 VM/hostname (default: k8s-worker-2)
  --worker3-name NAME       Worker-3 VM/hostname (default: k8s-worker-3)
  --vmrun PATH              Windows path to vmrun.exe
  --vmware-exe PATH         Windows path to vmware.exe (auto-detect when empty)
  --powershell-bin CMD      PowerShell command (default: powershell.exe)
  --vm-start-mode MODE      vmrun start mode: gui|nogui (default: nogui)
  --skip-workstation-register
                            Skip opening VMX files in VMware UI (inventory registration)

  --skip-build              Skip control-plane Packer build and reuse existing VMX
  --force-build             Pass --force to vmware_build_vm.sh (includes output_directory cleanup)
  --force-recreate-workers  Remove existing worker clones and create fresh clones
  --skip-bootstrap          Skip bootstrap_3node_k8s_ova.sh (only build/clone/start)
  --skip-overlay-apply      Keep join but skip overlay apply

  --static-network          Configure static IP/netplan via bootstrap script
  --control-plane-ip IP     Final static IP for control-plane (required with --static-network)
  --worker1-ip IP           Final static IP for worker-1 (required with --static-network)
  --worker2-ip IP           Final static IP for worker-2 (required with --static-network)
  --worker3-ip IP           Final static IP for worker-3 (required with --static-network)
  --gateway IP              Gateway for static network (required with --static-network)
  --network-cidr-prefix N   Prefix for static network (default: 24)
  --dns-servers CSV         DNS CSV (default with static network: <gateway>,1.1.1.1,8.8.8.8)
  --net-interface IFACE     Net interface (optional, auto-detect when empty)

  --ssh-user USER           SSH user override (defaults from vars file ssh_username)
  --ssh-password PASS       SSH password override (defaults from vars file ssh_password)
  --ssh-key-path PATH       SSH private key path (optional)
  --ssh-port PORT           SSH port (default: 22)
  --token-ttl DURATION      kubeadm token ttl (default: 2h)
  --env dev|prod            Overlay environment (default: dev)
  --overlay NAME            Overlay name (default: dev-3node)
  --remote-repo-root PATH   Remote repo root (default: /opt/k8s-data-platform)
  --skip-ingress-setup      Skip ingress-nginx + MetalLB setup after overlay apply
  --metallb-range RANGE     MetalLB address range, e.g. 192.168.56.240-192.168.56.250
  --ingress-lb-ip IP        Fixed ingress LoadBalancer IP inside the MetalLB range
  --metallb-manifest REF    MetalLB manifest URL/path override (advanced)
  --ingress-manifest REF    ingress-nginx manifest URL/path override (advanced)
  --wait-ip-timeout-sec N   Timeout per VM IP wait (default: 600)
  -h, --help                Show this help

Notes:
  - Without --static-network, current DHCP IPs are used (SKIP_NETWORK=1).
  - Existing worker VMX files are reused; absent ones are cloned.
EOF
}

cleanup() {
  if [[ -n "${RUNTIME_DIR}" && -d "${RUNTIME_DIR}" ]]; then
    rm -rf "${RUNTIME_DIR}"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  grep -qi microsoft /proc/version 2>/dev/null
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
    log "Stopping running VM (${label}) before clone/export safety"
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
  log "Starting VM (${label}) with mode=${VM_START_MODE}"
  ps_run "& '${VMRUN_WIN}' start '${vmx_win}' '${VM_START_MODE}'"
}

wait_for_vm_ip() {
  local vmx_win="$1"
  local label="$2"
  local attempts
  local ip
  local i

  attempts=$(( WAIT_IP_TIMEOUT_SEC / 5 ))
  if [[ "${attempts}" -lt 1 ]]; then
    attempts=1
  fi

  for i in $(seq 1 "${attempts}"); do
    ip="$(ps_capture "\$ip = & '${VMRUN_WIN}' getGuestIPAddress '${vmx_win}' 2>\$null; if (\$LASTEXITCODE -eq 0) { \$ip }" | tail -n 1)"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done

  die "Unable to get guest IP in time (${label})."
}

write_vm_name_vars_file() {
  local base_file="$1"
  local out_file="$2"
  local vm_name="$3"

  awk -v vm_name="${vm_name}" '
    BEGIN { replaced=0 }
    /^[[:space:]]*vm_name[[:space:]]*=/ {
      print "vm_name                   = \"" vm_name "\""
      replaced=1
      next
    }
    { print }
    END {
      if (!replaced) {
        print "vm_name = \"" vm_name "\""
      }
    }
  ' "${base_file}" > "${out_file}"
}

set_vmx_display_name() {
  local vmx_file="$1"
  local display_name="$2"
  local tmp_file

  if [[ ! -f "${vmx_file}" ]]; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v display_name="${display_name}" '
    BEGIN {
      replaced = 0
    }
    {
      line = tolower($0)
      if (line ~ /^[[:space:]]*displayname[[:space:]]*=/) {
        if (!replaced) {
          print "displayname = \"" display_name "\""
          replaced = 1
        }
        next
      }
      print $0
    }
    END {
      if (!replaced) {
        print "displayname = \"" display_name "\""
      }
    }
  ' "${vmx_file}" > "${tmp_file}"

  mv "${tmp_file}" "${vmx_file}"
}

resolve_vmware_exe() {
  local from_vars
  local candidate
  local unix_candidate
  local candidates=()

  if [[ -n "${VMWARE_EXE_WIN}" ]]; then
    candidates+=("${VMWARE_EXE_WIN}")
  fi

  from_vars="$(read_optional_packer_var "${CP_VARS_FILE}" vmware_workstation_path)"
  if [[ -n "${from_vars}" ]]; then
    if [[ "${from_vars,,}" == *.exe ]]; then
      candidates+=("${from_vars}")
    else
      from_vars="${from_vars%/}"
      from_vars="${from_vars%\\}"
      candidates+=("${from_vars}/vmware.exe")
    fi
  fi

  candidates+=(
    "C:/Program Files (x86)/VMware/VMware Workstation/vmware.exe"
    "C:/Program Files/VMware/VMware Workstation/vmware.exe"
  )

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    if [[ "${candidate}" == /* ]]; then
      candidate="$(to_windows_path "${candidate}")"
    fi
    unix_candidate="$(to_unix_path "${candidate}")"
    if [[ -f "${unix_candidate}" ]]; then
      VMWARE_EXE_WIN="$(normalize_win_path "$(to_windows_path "${unix_candidate}")")"
      return 0
    fi
  done

  die "vmware.exe not found. Provide --vmware-exe or set vmware_workstation_path in var file."
}

register_vm_in_workstation() {
  local vmx_win="$1"
  local label="$2"

  if [[ "${REGISTER_IN_WORKSTATION}" -ne 1 ]]; then
    return 0
  fi

  log "Registering VM in VMware Workstation UI (${label})"
  ps_run "if (!(Test-Path -LiteralPath '${vmx_win}')) { throw 'VMX not found: ${vmx_win}' }; Start-Process -FilePath '${VMWARE_EXE_WIN}' -ArgumentList @('${vmx_win}') | Out-Null"
}

ensure_worker_clone() {
  local worker_name="$1"
  local worker_vmx_win="$2"
  local worker_vmx_wsl="$3"

  if [[ -f "${worker_vmx_wsl}" && "${FORCE_RECREATE_WORKERS}" -eq 1 ]]; then
    stop_vm_if_running "${worker_vmx_win}" "${worker_name}"
    log "Removing existing worker clone (${worker_name})"
    ps_run "\$workerDir = Split-Path -Parent '${worker_vmx_win}'; if (Test-Path -LiteralPath \$workerDir) { Remove-Item -LiteralPath \$workerDir -Recurse -Force }"
  fi

  if [[ -f "${worker_vmx_wsl}" ]]; then
    log "Reusing existing worker VMX: ${worker_vmx_wsl}"
  else
    ps_run "New-Item -ItemType Directory -Force -Path (Split-Path -Parent '${worker_vmx_win}') | Out-Null"
    ps_run "& '${VMRUN_WIN}' clone '${CONTROL_PLANE_VMX_WIN}' '${worker_vmx_win}' full"
    [[ -f "${worker_vmx_wsl}" ]] || die "Worker clone failed (${worker_name}): ${worker_vmx_wsl}"
    set_vmx_display_name "${worker_vmx_wsl}" "${worker_name}"
  fi
}

write_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"
  printf '%s=%q\n' "${key}" "${value}" >> "${file}"
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
    --vmrun)
      [[ $# -ge 2 ]] || die "--vmrun requires a value"
      VMRUN_WIN="$2"
      shift 2
      ;;
    --vmware-exe)
      [[ $# -ge 2 ]] || die "--vmware-exe requires a value"
      VMWARE_EXE_WIN="$2"
      shift 2
      ;;
    --powershell-bin)
      [[ $# -ge 2 ]] || die "--powershell-bin requires a value"
      POWERSHELL_BIN="$2"
      shift 2
      ;;
    --vm-start-mode)
      [[ $# -ge 2 ]] || die "--vm-start-mode requires a value"
      VM_START_MODE="${2,,}"
      shift 2
      ;;
    --skip-workstation-register)
      REGISTER_IN_WORKSTATION=0
      shift
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
    --skip-bootstrap)
      SKIP_BOOTSTRAP=1
      shift
      ;;
    --skip-overlay-apply)
      APPLY_OVERLAY=0
      shift
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
    --token-ttl)
      [[ $# -ge 2 ]] || die "--token-ttl requires a value"
      TOKEN_TTL="$2"
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
    --skip-ingress-setup)
      SETUP_INGRESS_STACK=0
      shift
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
    --metallb-manifest)
      [[ $# -ge 2 ]] || die "--metallb-manifest requires a value"
      METALLB_MANIFEST="$2"
      shift 2
      ;;
    --ingress-manifest)
      [[ $# -ge 2 ]] || die "--ingress-manifest requires a value"
      INGRESS_MANIFEST="$2"
      shift 2
      ;;
    --wait-ip-timeout-sec)
      [[ $# -ge 2 ]] || die "--wait-ip-timeout-sec requires a value"
      WAIT_IP_TIMEOUT_SEC="$2"
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

is_wsl || die "This script must be executed inside WSL."
require_command wslpath
require_command awk
require_command "${POWERSHELL_BIN}"

if is_windows_style_path "${PACKER_VARS}"; then
  PACKER_VARS="$(to_unix_path "${PACKER_VARS}")"
fi
[[ -f "${PACKER_VARS}" ]] || die "Packer var file not found: ${PACKER_VARS}"

VMRUN_UNIX="$(to_unix_path "${VMRUN_WIN}")"
[[ -f "${VMRUN_UNIX}" ]] || die "vmrun.exe not found: ${VMRUN_WIN}"
VMRUN_WIN="$(normalize_win_path "$(to_windows_path "${VMRUN_UNIX}")")"

case "${VM_START_MODE}" in
  gui|nogui) ;;
  *)
    die "--vm-start-mode must be one of: gui, nogui"
    ;;
esac

if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
  [[ -n "${CONTROL_PLANE_IP}" ]] || die "--control-plane-ip is required with --static-network"
  [[ -n "${WORKER1_IP}" ]] || die "--worker1-ip is required with --static-network"
  [[ -n "${WORKER2_IP}" ]] || die "--worker2-ip is required with --static-network"
  [[ -n "${WORKER3_IP}" ]] || die "--worker3-ip is required with --static-network"
  [[ -n "${GATEWAY}" ]] || die "--gateway is required with --static-network"
  if [[ -z "${DNS_SERVERS}" ]]; then
    DNS_SERVERS="${GATEWAY},1.1.1.1,8.8.8.8"
  fi
fi

if [[ "${CONTROL_PLANE_NAME}" == "${WORKER1_NAME}" || "${CONTROL_PLANE_NAME}" == "${WORKER2_NAME}" || "${CONTROL_PLANE_NAME}" == "${WORKER3_NAME}" || "${WORKER1_NAME}" == "${WORKER2_NAME}" || "${WORKER1_NAME}" == "${WORKER3_NAME}" || "${WORKER2_NAME}" == "${WORKER3_NAME}" ]]; then
  die "VM names must be unique across control-plane/worker1/worker2/worker3."
fi

RUNTIME_DIR="$(mktemp -d)"
trap cleanup EXIT

CP_VARS_FILE="${RUNTIME_DIR}/control-plane.auto.pkrvars.hcl"
write_vm_name_vars_file "${PACKER_VARS}" "${CP_VARS_FILE}" "${CONTROL_PLANE_NAME}"

if [[ "${REGISTER_IN_WORKSTATION}" -eq 1 ]]; then
  resolve_vmware_exe
fi

if [[ -z "${SSH_USER}" ]]; then
  SSH_USER="$(read_packer_var "${CP_VARS_FILE}" ssh_username)"
fi
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_KEY_PATH}" ]]; then
  SSH_PASSWORD="$(read_optional_packer_var "${CP_VARS_FILE}" ssh_password)"
fi

if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

OUTPUT_DIR_RAW="$(read_packer_var "${CP_VARS_FILE}" output_directory)"
if is_windows_style_path "${OUTPUT_DIR_RAW}"; then
  OUTPUT_DIR_WSL="$(to_unix_path "${OUTPUT_DIR_RAW}")"
  OUTPUT_DIR_WIN="$(normalize_win_path "${OUTPUT_DIR_RAW}")"
elif [[ "${OUTPUT_DIR_RAW}" = /* ]]; then
  OUTPUT_DIR_WSL="${OUTPUT_DIR_RAW}"
  OUTPUT_DIR_WIN="$(normalize_win_path "$(to_windows_path "${OUTPUT_DIR_RAW}")")"
else
  OUTPUT_DIR_WSL="${PACKER_DIR}/${OUTPUT_DIR_RAW}"
  OUTPUT_DIR_WIN="$(normalize_win_path "$(to_windows_path "${PACKER_DIR}/${OUTPUT_DIR_RAW}")")"
fi

CONTROL_PLANE_VMX_WSL="${OUTPUT_DIR_WSL}/${CONTROL_PLANE_NAME}.vmx"
CONTROL_PLANE_VMX_WIN="$(normalize_win_path "$(to_windows_path "${CONTROL_PLANE_VMX_WSL}")")"

WORKER1_VMX_WIN="${OUTPUT_DIR_WIN%/}/${WORKER1_NAME}/${WORKER1_NAME}.vmx"
WORKER2_VMX_WIN="${OUTPUT_DIR_WIN%/}/${WORKER2_NAME}/${WORKER2_NAME}.vmx"
WORKER3_VMX_WIN="${OUTPUT_DIR_WIN%/}/${WORKER3_NAME}/${WORKER3_NAME}.vmx"
WORKER1_VMX_WSL="$(to_unix_path "${WORKER1_VMX_WIN}")"
WORKER2_VMX_WSL="$(to_unix_path "${WORKER2_VMX_WIN}")"
WORKER3_VMX_WSL="$(to_unix_path "${WORKER3_VMX_WIN}")"

if [[ "${SKIP_BUILD}" -eq 0 ]]; then
  log "Step 1/4: Building control-plane VM (${CONTROL_PLANE_NAME})"
  build_cmd=(bash "${ROOT_DIR}/scripts/vmware_build_vm.sh" --vars-file "${CP_VARS_FILE}")
  if [[ "${FORCE_BUILD}" -eq 1 ]]; then
    build_cmd+=(--force)
  fi
  "${build_cmd[@]}"
else
  log "Step 1/4: Skipping build and reusing existing control-plane VMX"
fi

[[ -f "${CONTROL_PLANE_VMX_WSL}" ]] || die "Control-plane VMX not found: ${CONTROL_PLANE_VMX_WSL}"
stop_vm_if_running "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}"

log "Step 2/4: Ensuring worker clones exist"
ensure_worker_clone "${WORKER1_NAME}" "${WORKER1_VMX_WIN}" "${WORKER1_VMX_WSL}"
ensure_worker_clone "${WORKER2_NAME}" "${WORKER2_VMX_WIN}" "${WORKER2_VMX_WSL}"
ensure_worker_clone "${WORKER3_NAME}" "${WORKER3_VMX_WIN}" "${WORKER3_VMX_WSL}"

if [[ "${REGISTER_IN_WORKSTATION}" -eq 1 ]]; then
  log "Step 2.5/4: Registering VMX files in VMware Workstation UI"
  register_vm_in_workstation "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}"
  register_vm_in_workstation "${WORKER1_VMX_WIN}" "${WORKER1_NAME}"
  register_vm_in_workstation "${WORKER2_VMX_WIN}" "${WORKER2_NAME}"
  register_vm_in_workstation "${WORKER3_VMX_WIN}" "${WORKER3_NAME}"
fi

log "Step 3/4: Starting VMs"
start_vm_if_needed "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}"
start_vm_if_needed "${WORKER1_VMX_WIN}" "${WORKER1_NAME}"
start_vm_if_needed "${WORKER2_VMX_WIN}" "${WORKER2_NAME}"
start_vm_if_needed "${WORKER3_VMX_WIN}" "${WORKER3_NAME}"

log "Waiting for guest IPs from VMware Tools"
CONTROL_PLANE_SSH_HOST="$(wait_for_vm_ip "${CONTROL_PLANE_VMX_WIN}" "${CONTROL_PLANE_NAME}")"
WORKER1_SSH_HOST="$(wait_for_vm_ip "${WORKER1_VMX_WIN}" "${WORKER1_NAME}")"
WORKER2_SSH_HOST="$(wait_for_vm_ip "${WORKER2_VMX_WIN}" "${WORKER2_NAME}")"
WORKER3_SSH_HOST="$(wait_for_vm_ip "${WORKER3_VMX_WIN}" "${WORKER3_NAME}")"

if [[ "${CONTROL_PLANE_SSH_HOST}" == "${WORKER1_SSH_HOST}" || "${CONTROL_PLANE_SSH_HOST}" == "${WORKER2_SSH_HOST}" || "${CONTROL_PLANE_SSH_HOST}" == "${WORKER3_SSH_HOST}" || "${WORKER1_SSH_HOST}" == "${WORKER2_SSH_HOST}" || "${WORKER1_SSH_HOST}" == "${WORKER3_SSH_HOST}" || "${WORKER2_SSH_HOST}" == "${WORKER3_SSH_HOST}" ]]; then
  if [[ "${SKIP_BOOTSTRAP}" -eq 1 ]]; then
    log "WARNING: Duplicate DHCP IPs detected across VMs (${CONTROL_PLANE_SSH_HOST}, ${WORKER1_SSH_HOST}, ${WORKER2_SSH_HOST}, ${WORKER3_SSH_HOST})."
    log "WARNING: For stable multi-node bootstrap, rerun with --static-network and unique IPs."
  elif [[ "${STATIC_NETWORK}" -eq 1 ]]; then
    log "WARNING: Duplicate DHCP IPs detected across VMs (${CONTROL_PLANE_SSH_HOST}, ${WORKER1_SSH_HOST}, ${WORKER2_SSH_HOST}, ${WORKER3_SSH_HOST})."
    log "WARNING: Continuing because --static-network is enabled; bootstrap will assign unique static IPs."
  else
    die "Duplicate DHCP IPs detected across VMs (${CONTROL_PLANE_SSH_HOST}, ${WORKER1_SSH_HOST}, ${WORKER2_SSH_HOST}, ${WORKER3_SSH_HOST}). Rerun with --static-network and unique control-plane/worker IPs."
  fi
fi

if [[ "${SKIP_BOOTSTRAP}" -eq 1 ]]; then
  log "Step 4/4: Bootstrap skipped (--skip-bootstrap)"
  echo "control-plane (${CONTROL_PLANE_NAME}) IP: ${CONTROL_PLANE_SSH_HOST}"
  echo "worker-1 (${WORKER1_NAME}) IP: ${WORKER1_SSH_HOST}"
  echo "worker-2 (${WORKER2_NAME}) IP: ${WORKER2_SSH_HOST}"
  echo "worker-3 (${WORKER3_NAME}) IP: ${WORKER3_SSH_HOST}"
  exit 0
fi

if [[ "${STATIC_NETWORK}" -eq 0 ]]; then
  CONTROL_PLANE_IP="${CONTROL_PLANE_SSH_HOST}"
  WORKER1_IP="${WORKER1_SSH_HOST}"
  WORKER2_IP="${WORKER2_SSH_HOST}"
  WORKER3_IP="${WORKER3_SSH_HOST}"
fi

BOOTSTRAP_CONFIG="${RUNTIME_DIR}/3node-bootstrap.env"
: > "${BOOTSTRAP_CONFIG}"

write_env_var "${BOOTSTRAP_CONFIG}" SSH_USER "${SSH_USER}"
if [[ -n "${SSH_PASSWORD}" ]]; then
  write_env_var "${BOOTSTRAP_CONFIG}" SSH_PASSWORD "${SSH_PASSWORD}"
fi
if [[ -n "${SSH_KEY_PATH}" ]]; then
  write_env_var "${BOOTSTRAP_CONFIG}" SSH_KEY_PATH "${SSH_KEY_PATH}"
fi
write_env_var "${BOOTSTRAP_CONFIG}" SSH_PORT "${SSH_PORT}"

write_env_var "${BOOTSTRAP_CONFIG}" CONTROL_PLANE_SSH_HOST "${CONTROL_PLANE_SSH_HOST}"
write_env_var "${BOOTSTRAP_CONFIG}" CONTROL_PLANE_HOSTNAME "${CONTROL_PLANE_NAME}"
write_env_var "${BOOTSTRAP_CONFIG}" CONTROL_PLANE_IP "${CONTROL_PLANE_IP}"

write_env_var "${BOOTSTRAP_CONFIG}" WORKER1_SSH_HOST "${WORKER1_SSH_HOST}"
write_env_var "${BOOTSTRAP_CONFIG}" WORKER1_HOSTNAME "${WORKER1_NAME}"
write_env_var "${BOOTSTRAP_CONFIG}" WORKER1_IP "${WORKER1_IP}"

write_env_var "${BOOTSTRAP_CONFIG}" WORKER2_SSH_HOST "${WORKER2_SSH_HOST}"
write_env_var "${BOOTSTRAP_CONFIG}" WORKER2_HOSTNAME "${WORKER2_NAME}"
write_env_var "${BOOTSTRAP_CONFIG}" WORKER2_IP "${WORKER2_IP}"

write_env_var "${BOOTSTRAP_CONFIG}" WORKER3_SSH_HOST "${WORKER3_SSH_HOST}"
write_env_var "${BOOTSTRAP_CONFIG}" WORKER3_HOSTNAME "${WORKER3_NAME}"
write_env_var "${BOOTSTRAP_CONFIG}" WORKER3_IP "${WORKER3_IP}"

write_env_var "${BOOTSTRAP_CONFIG}" NETWORK_CIDR_PREFIX "${NETWORK_CIDR_PREFIX}"
write_env_var "${BOOTSTRAP_CONFIG}" GATEWAY "${GATEWAY}"
write_env_var "${BOOTSTRAP_CONFIG}" DNS_SERVERS "${DNS_SERVERS}"
write_env_var "${BOOTSTRAP_CONFIG}" NET_INTERFACE "${NET_INTERFACE}"

write_env_var "${BOOTSTRAP_CONFIG}" TOKEN_TTL "${TOKEN_TTL}"
write_env_var "${BOOTSTRAP_CONFIG}" SKIP_NETWORK "$(( 1 - STATIC_NETWORK ))"
write_env_var "${BOOTSTRAP_CONFIG}" SKIP_JOIN "0"
write_env_var "${BOOTSTRAP_CONFIG}" APPLY_OVERLAY "${APPLY_OVERLAY}"
write_env_var "${BOOTSTRAP_CONFIG}" ENVIRONMENT "${ENVIRONMENT}"
write_env_var "${BOOTSTRAP_CONFIG}" OVERLAY "${OVERLAY}"
write_env_var "${BOOTSTRAP_CONFIG}" REMOTE_REPO_ROOT "${REMOTE_REPO_ROOT}"
write_env_var "${BOOTSTRAP_CONFIG}" SETUP_INGRESS_STACK "${SETUP_INGRESS_STACK}"
write_env_var "${BOOTSTRAP_CONFIG}" METALLB_ADDRESS_RANGE "${METALLB_ADDRESS_RANGE}"
write_env_var "${BOOTSTRAP_CONFIG}" INGRESS_LB_IP "${INGRESS_LB_IP}"
write_env_var "${BOOTSTRAP_CONFIG}" METALLB_MANIFEST "${METALLB_MANIFEST}"
write_env_var "${BOOTSTRAP_CONFIG}" INGRESS_MANIFEST "${INGRESS_MANIFEST}"

log "Step 4/4: Bootstrapping cluster (control-plane + worker1/2/3)"
bash "${ROOT_DIR}/scripts/bootstrap_3node_k8s_ova.sh" --config "${BOOTSTRAP_CONFIG}"

log "Provisioning completed."
echo "control-plane VMX: ${CONTROL_PLANE_VMX_WSL}"
echo "worker-1 VMX: ${WORKER1_VMX_WSL}"
echo "worker-2 VMX: ${WORKER2_VMX_WSL}"
echo "worker-3 VMX: ${WORKER3_VMX_WSL}"
echo "control-plane IP: ${CONTROL_PLANE_IP}"
echo "worker-1 IP: ${WORKER1_IP}"
echo "worker-2 IP: ${WORKER2_IP}"
echo "worker-3 IP: ${WORKER3_IP}"
