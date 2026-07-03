#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
SOURCE_VMX=""
BASTION_NAME="${BASTION_NAME:-bh}"

POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
VMRUN_WIN="${VMRUN_WIN:-C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe}"
VMWARE_EXE_WIN="${VMWARE_EXE_WIN:-}"
VM_START_MODE="${VM_START_MODE:-nogui}"
REGISTER_IN_WORKSTATION=1
FORCE_RECREATE=0

SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"

SETUP_EDUMGT=1
EDUMGT_PASSWORD="${EDUMGT_PASSWORD:-CHANGE_ME}"
INSTALL_PDSH=1
PDSH_RCMD_TYPE="${PDSH_RCMD_TYPE:-ssh}"
PDSH_GROUP_NAME="${PDSH_GROUP_NAME:-k8s-dev}"
PDSH_GROUP_HOSTS="${PDSH_GROUP_HOSTS:-}"

STATIC_NETWORK=0
STATIC_IP=""
NETWORK_CIDR_PREFIX="${NETWORK_CIDR_PREFIX:-24}"
GATEWAY=""
DNS_SERVERS=""
NET_INTERFACE=""

RUNTIME_DIR=""

usage() {
  cat <<'EOF'
Usage: bash scripts/vmware_create_bastion_bh.sh [options]

Creates one VMware guest VM named `bh` for bastion practice and prepares access tools.

What this script does:
  1) Clone SOURCE VMX into <output>/<bastion-name>/<bastion-name>.vmx
  2) Start VM (gui or nogui)
  3) Wait for guest IP from VMware Tools
  4) Configure guest:
     - hostname
     - edumgt account + passwordless sudo
     - pdsh/ssh utilities
     - optional static IP
     - optional pdsh host group file

Options:
  --vars-file PATH           Packer vars file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --source-vmx PATH          Source VMX path. If omitted, uses output_directory/vm_name.vmx from vars file.
  --bastion-name NAME        Bastion VM/hostname (default: bh)

  --vmrun PATH               Windows path to vmrun.exe
  --vmware-exe PATH          Windows path to vmware.exe
  --powershell-bin CMD       PowerShell command (default: powershell.exe)
  --vm-start-mode MODE       gui|nogui (default: nogui)
  --skip-workstation-register
  --force-recreate           Remove existing bh clone then recreate

  --ssh-user USER            SSH user to bootstrap guest (default: ssh_username from vars)
  --ssh-password PASS        SSH password (default: ssh_password from vars)
  --ssh-key-path PATH        SSH private key path
  --ssh-port PORT            SSH port (default: 22)

  --skip-setup-edumgt        Do not create/update edumgt user
  --edumgt-password PASS     Password for edumgt (default: CHANGE_ME)
  --skip-install-pdsh        Skip apt install pdsh/sshpass/openssh-client
  --pdsh-rcmd-type TYPE      pdsh remote cmd type (default: ssh)
  --pdsh-group-name NAME     pdsh group file name under /home/edumgt/.dsh/group (default: k8s-dev)
  --pdsh-group-hosts CSV     Comma-separated host list for pdsh group file

  --static-network           Configure static netplan
  --static-ip IP             Required when --static-network
  --network-cidr-prefix N    Prefix (default: 24)
  --gateway IP               Required when --static-network
  --dns-servers CSV          DNS list, default: <gateway>,1.1.1.1,8.8.8.8
  --net-interface IFACE      Optional interface; auto-detect if empty

  -h, --help                 Show help

Examples:
  bash scripts/vmware_create_bastion_bh.sh \
    --source-vmx /mnt/c/ffmpeg/output-k8s-data-platform-vmware/k8s-data-platform-vmware.vmx \
    --ssh-user ubuntu --ssh-password ubuntu

  bash scripts/vmware_create_bastion_bh.sh \
    --static-network --static-ip <YOUR_BASTION_INTERNAL_IP> --gateway <YOUR_GATEWAY_IP> \
    --dns-servers <YOUR_GATEWAY_IP>,1.1.1.1 \
    --pdsh-group-hosts <YOUR_MASTER_IP>,<YOUR_WORKER1_IP>,<YOUR_WORKER2_IP>,<YOUR_WORKER_ML1_IP>
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${RUNTIME_DIR}" && -d "${RUNTIME_DIR}" ]]; then
    rm -rf "${RUNTIME_DIR}"
  fi
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
  if vm_is_running "${vmx_win}"; then
    log "Stopping running VM before clone/update"
    ps_run "& '${VMRUN_WIN}' stop '${vmx_win}' soft; if (\$LASTEXITCODE -ne 0) { & '${VMRUN_WIN}' stop '${vmx_win}' hard }"
  fi
}

start_vm_if_needed() {
  local vmx_win="$1"
  if vm_is_running "${vmx_win}"; then
    log "VM already running"
    return 0
  fi
  ps_run "& '${VMRUN_WIN}' start '${vmx_win}' '${VM_START_MODE}'"
}

wait_for_vm_ip() {
  local vmx_win="$1"
  local timeout_sec="${2:-600}"
  local attempts
  local ip
  local i

  attempts=$(( timeout_sec / 5 ))
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
  die "Unable to get guest IP in time."
}

escape_single_quotes() {
  printf "%s" "$1" | sed "s/'/'\"'\"'/g"
}

ssh_run() {
  local host="$1"
  shift

  local ssh_opts=(
    -p "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=8
  )
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    ssh_opts+=(-i "${SSH_KEY_PATH}")
  fi

  if [[ -n "${SSH_PASSWORD}" ]]; then
    SSHPASS="${SSH_PASSWORD}" sshpass -e ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
    return
  fi
  ssh "${ssh_opts[@]}" "${SSH_USER}@${host}" "$@"
}

ssh_run_sudo() {
  local host="$1"
  local command="$2"
  local escaped_command
  escaped_command="$(escape_single_quotes "${command}")"

  if [[ -n "${SSH_PASSWORD}" ]]; then
    local escaped_pw
    escaped_pw="$(escape_single_quotes "${SSH_PASSWORD}")"
    ssh_run "${host}" "printf '%s\n' '${escaped_pw}' | sudo -S -p '' bash -lc '${escaped_command}'"
    return
  fi
  ssh_run "${host}" "sudo bash -lc '${escaped_command}'"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --source-vmx)
      [[ $# -ge 2 ]] || die "--source-vmx requires a value"
      SOURCE_VMX="$2"
      shift 2
      ;;
    --bastion-name)
      [[ $# -ge 2 ]] || die "--bastion-name requires a value"
      BASTION_NAME="$2"
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
    --force-recreate)
      FORCE_RECREATE=1
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
    --skip-setup-edumgt)
      SETUP_EDUMGT=0
      shift
      ;;
    --edumgt-password)
      [[ $# -ge 2 ]] || die "--edumgt-password requires a value"
      EDUMGT_PASSWORD="$2"
      shift 2
      ;;
    --skip-install-pdsh)
      INSTALL_PDSH=0
      shift
      ;;
    --pdsh-rcmd-type)
      [[ $# -ge 2 ]] || die "--pdsh-rcmd-type requires a value"
      PDSH_RCMD_TYPE="$2"
      shift 2
      ;;
    --pdsh-group-name)
      [[ $# -ge 2 ]] || die "--pdsh-group-name requires a value"
      PDSH_GROUP_NAME="$2"
      shift 2
      ;;
    --pdsh-group-hosts)
      [[ $# -ge 2 ]] || die "--pdsh-group-hosts requires a value"
      PDSH_GROUP_HOSTS="$2"
      shift 2
      ;;
    --static-network)
      STATIC_NETWORK=1
      shift
      ;;
    --static-ip)
      [[ $# -ge 2 ]] || die "--static-ip requires a value"
      STATIC_IP="$2"
      shift 2
      ;;
    --network-cidr-prefix)
      [[ $# -ge 2 ]] || die "--network-cidr-prefix requires a value"
      NETWORK_CIDR_PREFIX="$2"
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
    --net-interface)
      [[ $# -ge 2 ]] || die "--net-interface requires a value"
      NET_INTERFACE="$2"
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

if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

if is_windows_style_path "${PACKER_VARS}"; then
  PACKER_VARS="$(to_unix_path "${PACKER_VARS}")"
fi
[[ -f "${PACKER_VARS}" ]] || die "Packer var file not found: ${PACKER_VARS}"

VMRUN_UNIX="$(to_unix_path "${VMRUN_WIN}")"
[[ -f "${VMRUN_UNIX}" ]] || die "vmrun.exe not found: ${VMRUN_WIN}"
VMRUN_WIN="$(normalize_win_path "$(to_windows_path "${VMRUN_UNIX}")")"

case "${VM_START_MODE}" in
  gui|nogui) ;;
  *) die "--vm-start-mode must be gui or nogui" ;;
esac

if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
  [[ -n "${STATIC_IP}" ]] || die "--static-ip is required with --static-network"
  [[ -n "${GATEWAY}" ]] || die "--gateway is required with --static-network"
  if [[ -z "${DNS_SERVERS}" ]]; then
    DNS_SERVERS="${GATEWAY},1.1.1.1,8.8.8.8"
  fi
fi

if [[ -z "${SOURCE_VMX}" ]]; then
  source_vm_name="$(read_packer_var "${PACKER_VARS}" vm_name)"
  output_dir_raw="$(read_packer_var "${PACKER_VARS}" output_directory)"
  if is_windows_style_path "${output_dir_raw}"; then
    output_dir_wsl="$(to_unix_path "${output_dir_raw}")"
  elif [[ "${output_dir_raw}" = /* ]]; then
    output_dir_wsl="${output_dir_raw}"
  else
    output_dir_wsl="${PACKER_DIR}/${output_dir_raw}"
  fi
  SOURCE_VMX="${output_dir_wsl}/${source_vm_name}.vmx"
fi
[[ -f "${SOURCE_VMX}" ]] || die "Source VMX not found: ${SOURCE_VMX}"
SOURCE_VMX_WIN="$(normalize_win_path "$(to_windows_path "${SOURCE_VMX}")")"

if [[ -z "${SSH_USER}" ]]; then
  SSH_USER="$(read_packer_var "${PACKER_VARS}" ssh_username)"
fi
if [[ -z "${SSH_PASSWORD}" && -z "${SSH_KEY_PATH}" ]]; then
  SSH_PASSWORD="$(read_optional_packer_var "${PACKER_VARS}" ssh_password)"
fi
if [[ -n "${SSH_PASSWORD}" ]]; then
  require_command sshpass
fi

if [[ -z "${VMWARE_EXE_WIN}" && "${REGISTER_IN_WORKSTATION}" -eq 1 ]]; then
  from_vars="$(read_optional_packer_var "${PACKER_VARS}" vmware_workstation_path)"
  if [[ -n "${from_vars}" ]]; then
    if [[ "${from_vars,,}" == *.exe ]]; then
      VMWARE_EXE_WIN="${from_vars}"
    else
      VMWARE_EXE_WIN="${from_vars%/}/vmware.exe"
    fi
  else
    VMWARE_EXE_WIN="C:/Program Files (x86)/VMware/VMware Workstation/vmware.exe"
  fi
fi
if [[ "${REGISTER_IN_WORKSTATION}" -eq 1 ]]; then
  vmware_exe_unix="$(to_unix_path "${VMWARE_EXE_WIN}")"
  [[ -f "${vmware_exe_unix}" ]] || die "vmware.exe not found: ${VMWARE_EXE_WIN}"
  VMWARE_EXE_WIN="$(normalize_win_path "$(to_windows_path "${vmware_exe_unix}")")"
fi

source_dir_wsl="$(dirname "${SOURCE_VMX}")"
target_dir_wsl="${source_dir_wsl}/${BASTION_NAME}"
target_vmx_wsl="${target_dir_wsl}/${BASTION_NAME}.vmx"
target_vmx_win="$(normalize_win_path "$(to_windows_path "${target_vmx_wsl}")")"

if [[ -f "${target_vmx_wsl}" && "${FORCE_RECREATE}" -eq 1 ]]; then
  stop_vm_if_running "${target_vmx_win}"
  log "Removing existing bastion clone: ${target_dir_wsl}"
  ps_run "\$dir='$(normalize_win_path "$(to_windows_path "${target_dir_wsl}")")'; if (Test-Path -LiteralPath \$dir) { Remove-Item -LiteralPath \$dir -Recurse -Force }"
fi

if [[ ! -f "${target_vmx_wsl}" ]]; then
  log "Cloning bastion VM: ${BASTION_NAME}"
  ps_run "New-Item -ItemType Directory -Force -Path (Split-Path -Parent '${target_vmx_win}') | Out-Null"
  ps_run "& '${VMRUN_WIN}' clone '${SOURCE_VMX_WIN}' '${target_vmx_win}' full"
fi
[[ -f "${target_vmx_wsl}" ]] || die "Failed to create bastion VMX: ${target_vmx_wsl}"

stop_vm_if_running "${target_vmx_win}"
start_vm_if_needed "${target_vmx_win}"

log "Waiting for guest IP (VMware Tools)"
guest_ip="$(wait_for_vm_ip "${target_vmx_win}" 600)"
log "Guest DHCP IP detected: ${guest_ip}"

if [[ "${REGISTER_IN_WORKSTATION}" -eq 1 ]]; then
  log "Registering VM in VMware Workstation UI"
  ps_run "Start-Process -FilePath '${VMWARE_EXE_WIN}' -ArgumentList @('${target_vmx_win}') | Out-Null"
fi

log "Configuring bastion guest via SSH (${SSH_USER}@${guest_ip}:${SSH_PORT})"
ssh_run_sudo "${guest_ip}" "hostnamectl set-hostname '${BASTION_NAME}'"

if [[ "${SETUP_EDUMGT}" -eq 1 ]]; then
  escaped_edumgt_pw="$(escape_single_quotes "${EDUMGT_PASSWORD}")"
  ssh_run_sudo "${guest_ip}" "id -u edumgt >/dev/null 2>&1 || useradd -m -s /bin/bash edumgt"
  ssh_run_sudo "${guest_ip}" "printf '%s\n' 'edumgt:${escaped_edumgt_pw}' | chpasswd"
  ssh_run_sudo "${guest_ip}" "printf 'edumgt ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-edumgt-nopasswd && chmod 440 /etc/sudoers.d/90-edumgt-nopasswd"
fi

if [[ "${INSTALL_PDSH}" -eq 1 ]]; then
  ssh_run_sudo "${guest_ip}" "DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y pdsh openssh-client sshpass"
fi

if [[ -n "${PDSH_GROUP_HOSTS}" ]]; then
  group_lines="$(printf '%s' "${PDSH_GROUP_HOSTS}" | tr ',' '\n' | sed '/^[[:space:]]*$/d')"
  group_lines_b64="$(printf '%s' "${group_lines}" | base64 -w0)"
  ssh_run_sudo "${guest_ip}" "install -d -m 0755 -o edumgt -g edumgt /home/edumgt/.dsh/group"
  ssh_run_sudo "${guest_ip}" "printf '%s' '${group_lines_b64}' | base64 -d >/home/edumgt/.dsh/group/${PDSH_GROUP_NAME} && chown edumgt:edumgt /home/edumgt/.dsh/group/${PDSH_GROUP_NAME} && chmod 644 /home/edumgt/.dsh/group/${PDSH_GROUP_NAME}"
fi

if [[ -n "${PDSH_RCMD_TYPE}" ]]; then
  ssh_run_sudo "${guest_ip}" "install -d -m 0755 -o edumgt -g edumgt /home/edumgt && printf 'export PDSH_RCMD_TYPE=%s\n' '${PDSH_RCMD_TYPE}' >/home/edumgt/.bashrc.pdsh && chown edumgt:edumgt /home/edumgt/.bashrc.pdsh"
  ssh_run_sudo "${guest_ip}" "grep -q '.bashrc.pdsh' /home/edumgt/.bashrc || printf '\n[ -f ~/.bashrc.pdsh ] && . ~/.bashrc.pdsh\n' >> /home/edumgt/.bashrc && chown edumgt:edumgt /home/edumgt/.bashrc"
fi

if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
  dns_csv="${DNS_SERVERS}"
  iface="${NET_INTERFACE}"
  if [[ -z "${iface}" ]]; then
    iface_cmd="ip route | awk '/default/ {print \$5; exit}'"
    iface="$(ssh_run "${guest_ip}" "${iface_cmd}" | tr -d '\r' | tr -d '\n')"
  fi
  [[ -n "${iface}" ]] || die "Failed to detect guest interface; provide --net-interface."
  dns_yaml="$(printf '%s' "${dns_csv}" | awk -F',' '{for(i=1;i<=NF;i++) printf "%s\"%s\"", (i==1?"":", "), $i}')"
  static_script="$(cat <<EOF
set -euo pipefail
cat >/etc/netplan/99-bastion-static.yaml <<NETPLAN
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/${NETWORK_CIDR_PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
NETPLAN
chmod 600 /etc/netplan/99-bastion-static.yaml
netplan generate
netplan apply
EOF
)"
  static_script_b64="$(printf '%s' "${static_script}" | base64 -w0)"
  ssh_run_sudo "${guest_ip}" "printf '%s' '${static_script_b64}' | base64 -d >/tmp/bh-static-net.sh && bash /tmp/bh-static-net.sh"
  log "Static network applied: ${STATIC_IP}/${NETWORK_CIDR_PREFIX}"
fi

echo
echo "Bastion VM ready."
echo "  VMX: ${target_vmx_wsl}"
echo "  DHCP IP: ${guest_ip}"
if [[ "${STATIC_NETWORK}" -eq 1 ]]; then
  echo "  Static IP: ${STATIC_IP}"
fi
echo "  SSH: ssh -p ${SSH_PORT} ${SSH_USER}@${guest_ip}"
if [[ "${SETUP_EDUMGT}" -eq 1 ]]; then
  echo "  EDUMGT: ssh -p ${SSH_PORT} edumgt@${guest_ip}"
fi
if [[ -n "${PDSH_GROUP_HOSTS}" ]]; then
  echo "  pdsh test: ssh edumgt@${guest_ip} \"pdsh -g ${PDSH_GROUP_NAME} -w ^${PDSH_GROUP_NAME} 'hostname -I'\""
fi

