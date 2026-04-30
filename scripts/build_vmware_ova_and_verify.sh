#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"
PACKER_TEMPLATE="${PACKER_TEMPLATE:-${PACKER_DIR}/k8s-data-platform-vmware.pkr.hcl}"
PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"
POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
PACKER_EXE_WIN="${PACKER_EXE_WIN:-C:/Users/1/AppData/Local/Microsoft/WinGet/Links/packer.exe}"
VMRUN_WIN="${VMRUN_WIN:-C:/Program Files (x86)/VMware/VMware Workstation/vmrun.exe}"
OVFTOOL_WIN="${OVFTOOL_WIN:-}"
WIN_MIRROR_ROOT="${WIN_MIRROR_ROOT:-C:/Users/1/Kubernetes-Jupyter-Sandbox}"
PACKER_CACHE_DIR_WIN="${PACKER_CACHE_DIR_WIN:-C:/ffmpeg/packer-cache}"
PACKER_LOG_PATH_WIN="${PACKER_LOG_PATH_WIN:-C:/ffmpeg/packer-vmware-build.log}"

VM_USER="${VM_USER:-}"
VM_PASSWORD="${VM_PASSWORD:-}"
SSH_PORT="${SSH_PORT:-22}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

SKIP_PACKER_BUILD=0
SKIP_OVA_EXPORT=0
SKIP_VM_START=0
SKIP_VERIFY=0
FORCE_BUILD=0
VMRUN_UNIX=""

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/build_vmware_ova_and_verify.sh [options]

Runs this flow end-to-end:
  1) Packer(vmware-iso) init/validate/build
  2) vmrun start
  3) SSH verify for Kubernetes + pods + services
  4) OVF Tool export (vmx -> ova)

Options:
  --vars-file PATH       Override packer var file.
  --template PATH        Override packer template path.
  --dist-dir DIR         Override OVA output directory.
  --packer-exe PATH      Windows path to packer.exe.
  --vmrun PATH           Windows path to vmrun.exe.
  --ovftool PATH         Windows path to ovftool.exe.
  --vm-user USER         Guest SSH user (defaults from var file ssh_username).
  --vm-password PASS     Guest SSH password (defaults from var file ssh_password).
  --ssh-port PORT        Guest SSH port (default: 22).
  --env dev|prod         Verify environment namespace (default: dev).
  --force                Pass -force to packer build and clean existing output_directory.
  --skip-packer-build    Skip packer init/validate/build.
  --skip-vm-start        Skip vmrun start.
  --skip-verify          Skip SSH/Kubernetes verification.
  --skip-ova-export      Skip ovftool export.
  -h, --help             Show this help.
EOF
}

trim() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

read_optional_packer_var() {
  local key="$1"
  local raw_value

  raw_value="$(
    awk -F '=' -v key="${key}" '
      $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
        sub(/^[^=]*=/, "", $0)
        print $0
        exit
      }
    ' "${PACKER_VARS}"
  )"
  raw_value="$(trim "${raw_value}")"
  raw_value="${raw_value#\"}"
  raw_value="${raw_value%\"}"
  printf '%s' "${raw_value}"
}

read_packer_var() {
  local key="$1"
  local value
  value="$(read_optional_packer_var "${key}")"
  [[ -n "${value}" ]] || die "Required setting not found in ${PACKER_VARS}: ${key}"
  printf '%s' "${value}"
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

to_windows_path() {
  local path="$1"
  local root_unix
  local mirror_unix
  local rel

  if is_windows_style_path "${path}"; then
    printf '%s' "${path}"
    return 0
  fi

  root_unix="${ROOT_DIR%/}"
  mirror_unix="$(wslpath -u "${WIN_MIRROR_ROOT}" 2>/dev/null || true)"
  if [[ -n "${mirror_unix}" && -d "${mirror_unix}" ]]; then
    if [[ "${path}" == "${root_unix}" || "${path}" == "${root_unix}/"* ]]; then
      rel="${path#${root_unix}}"
      rel="${rel#/}"
      if [[ -n "${rel}" ]]; then
        printf '%s/%s' "${WIN_MIRROR_ROOT%/}" "${rel}"
      else
        printf '%s' "${WIN_MIRROR_ROOT}"
      fi
      return 0
    fi
  fi

  wslpath -w "${path}"
}

to_unix_path() {
  local path="$1"
  if is_windows_style_path "${path}"; then
    wslpath -u "${path}"
    return 0
  fi
  printf '%s' "${path}"
}

normalize_win_path() {
  printf '%s' "${1//\\//}"
}

ps_capture() {
  local command="$1"
  local attempt
  local tmp_out
  local tmp_err

  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  trap 'rm -f "${tmp_out}" "${tmp_err}"' RETURN

  for attempt in 1 2 3; do
    if "${POWERSHELL_BIN}" -NoProfile -Command "${command}" >"${tmp_out}" 2>"${tmp_err}"; then
      cat "${tmp_out}" | tr -d '\r'
      return 0
    fi
    if [[ "${attempt}" -lt 3 ]]; then
      sleep 1
      continue
    fi
    cat "${tmp_err}" >&2 || true
    cat "${tmp_out}" >&2 || true
    return 1
  done
}

ps_run() {
  local command="$1"
  local attempt
  local tmp_out
  local tmp_err

  tmp_out="$(mktemp)"
  tmp_err="$(mktemp)"
  trap 'rm -f "${tmp_out}" "${tmp_err}"' RETURN

  for attempt in 1 2 3; do
    if "${POWERSHELL_BIN}" -NoProfile -Command "${command}" >"${tmp_out}" 2>"${tmp_err}"; then
      cat "${tmp_out}"
      return 0
    fi
    if [[ "${attempt}" -lt 3 ]]; then
      sleep 1
      continue
    fi
    cat "${tmp_err}" >&2 || true
    cat "${tmp_out}" >&2 || true
    return 1
  done
}

resolve_packer_exe() {
  local from_path=""
  local from_powershell=""
  local candidates=(
    "${PACKER_EXE_WIN}"
    "C:/Users/1/AppData/Local/Microsoft/WinGet/Links/packer.exe"
    "C:/Program Files/HashiCorp/Packer/packer.exe"
  )
  local candidate
  local unix_candidate

  if command -v packer.exe >/dev/null 2>&1; then
    from_path="$(command -v packer.exe)"
    if [[ -n "${from_path}" ]]; then
      candidates=("${from_path}" "${candidates[@]}")
    fi
  fi

  from_powershell="$(ps_capture '$p = (Get-Command packer.exe -ErrorAction SilentlyContinue).Source; if ($p) { $p }')" || true
  from_powershell="$(trim "${from_powershell}")"
  if [[ -n "${from_powershell}" ]]; then
    candidates=("${from_powershell}" "${candidates[@]}")
  fi

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    if [[ "${candidate}" == /* ]]; then
      candidate="$(to_windows_path "${candidate}")"
    fi
    unix_candidate="$(to_unix_path "${candidate}")"
    if [[ -f "${unix_candidate}" ]]; then
      PACKER_EXE_WIN="$(normalize_win_path "$(to_windows_path "${unix_candidate}")")"
      return 0
    fi
  done

  die "packer.exe not found. Provide --packer-exe path."
}

resolve_ovftool() {
  local from_vars
  local candidates=()
  local candidate
  local unix_candidate

  from_vars="$(read_optional_packer_var ovftool_path_windows)"
  if [[ -n "${OVFTOOL_WIN}" ]]; then
    candidates+=("${OVFTOOL_WIN}")
  fi
  if [[ -n "${from_vars}" ]]; then
    candidates+=("${from_vars}")
  fi
  candidates+=(
    "C:/Program Files (x86)/VMware/VMware Workstation/OVFTool/ovftool.exe"
    "C:/Program Files/VMware/VMware OVF Tool/ovftool.exe"
  )

  for candidate in "${candidates[@]}"; do
    if [[ "${candidate}" == /* ]]; then
      candidate="$(to_windows_path "${candidate}")"
    fi
    unix_candidate="$(to_unix_path "${candidate}")"
    if [[ -f "${unix_candidate}" ]]; then
      OVFTOOL_WIN="${candidate}"
      return 0
    fi
  done

  die "ovftool.exe not found. Provide --ovftool or set ovftool_path_windows in var file."
}

wait_for_vm_ip() {
  local vmx_win="$1"
  local attempt
  local ip

  for attempt in $(seq 1 90); do
    ip="$(ps_capture "\$ip = & '${VMRUN_WIN}' getGuestIPAddress '${vmx_win}' 2>\$null; if (\$LASTEXITCODE -eq 0) { \$ip }" | tail -n 1)"
    if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "${ip}"
      return 0
    fi
    sleep 5
  done

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --template)
      [[ $# -ge 2 ]] || die "--template requires a value"
      PACKER_TEMPLATE="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || die "--dist-dir requires a value"
      DIST_DIR="$2"
      shift 2
      ;;
    --packer-exe)
      [[ $# -ge 2 ]] || die "--packer-exe requires a value"
      PACKER_EXE_WIN="$2"
      shift 2
      ;;
    --vmrun)
      [[ $# -ge 2 ]] || die "--vmrun requires a value"
      VMRUN_WIN="$2"
      shift 2
      ;;
    --ovftool)
      [[ $# -ge 2 ]] || die "--ovftool requires a value"
      OVFTOOL_WIN="$2"
      shift 2
      ;;
    --vm-user)
      [[ $# -ge 2 ]] || die "--vm-user requires a value"
      VM_USER="$2"
      shift 2
      ;;
    --vm-password)
      [[ $# -ge 2 ]] || die "--vm-password requires a value"
      VM_PASSWORD="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port requires a value"
      SSH_PORT="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --force)
      FORCE_BUILD=1
      shift
      ;;
    --skip-packer-build)
      SKIP_PACKER_BUILD=1
      shift
      ;;
    --skip-ova-export)
      SKIP_OVA_EXPORT=1
      shift
      ;;
    --skip-vm-start)
      SKIP_VM_START=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
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
if is_windows_style_path "${PACKER_TEMPLATE}"; then
  PACKER_TEMPLATE="$(to_unix_path "${PACKER_TEMPLATE}")"
fi
if is_windows_style_path "${DIST_DIR}"; then
  DIST_DIR="$(to_unix_path "${DIST_DIR}")"
fi

[[ -f "${PACKER_VARS}" ]] || die "Packer var file not found: ${PACKER_VARS}"
[[ -f "${PACKER_TEMPLATE}" ]] || die "Packer template not found: ${PACKER_TEMPLATE}"
is_wsl || die "This script must be executed inside WSL."

require_command "${POWERSHELL_BIN}"
require_command wslpath
if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
  require_command ssh
  require_command sshpass
fi

VM_NAME="$(read_packer_var vm_name)"
OUTPUT_DIR_RAW="$(read_packer_var output_directory)"
if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
  if [[ -z "${VM_USER}" ]]; then
    VM_USER="$(read_packer_var ssh_username)"
  fi
  if [[ -z "${VM_PASSWORD}" ]]; then
    VM_PASSWORD="$(read_packer_var ssh_password)"
  fi
fi

if is_windows_style_path "${OUTPUT_DIR_RAW}"; then
  OUTPUT_DIR_WSL="$(to_unix_path "${OUTPUT_DIR_RAW}")"
  OUTPUT_DIR_WIN="$(to_windows_path "${OUTPUT_DIR_RAW}")"
elif [[ "${OUTPUT_DIR_RAW}" = /* ]]; then
  OUTPUT_DIR_WSL="${OUTPUT_DIR_RAW}"
  OUTPUT_DIR_WIN="$(to_windows_path "${OUTPUT_DIR_RAW}")"
else
  OUTPUT_DIR_WSL="${PACKER_DIR}/${OUTPUT_DIR_RAW}"
  OUTPUT_DIR_WIN="$(to_windows_path "${PACKER_DIR}/${OUTPUT_DIR_RAW}")"
fi

mkdir -p "${DIST_DIR}"
VMX_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}.vmx"
OVA_PATH="${DIST_DIR}/${VM_NAME}.ova"

PACKER_DIR_WIN="$(to_windows_path "${PACKER_DIR}")"
PACKER_TEMPLATE_WIN="$(to_windows_path "${PACKER_TEMPLATE}")"
PACKER_VARS_WIN="$(to_windows_path "${PACKER_VARS}")"
VMX_WIN="$(to_windows_path "${VMX_PATH}")"
DIST_DIR_WIN="$(to_windows_path "${DIST_DIR}")"
OVA_WIN="$(to_windows_path "${OVA_PATH}")"

if [[ "${SKIP_PACKER_BUILD}" -eq 0 ]]; then
  resolve_packer_exe
fi
if [[ "${SKIP_OVA_EXPORT}" -eq 0 ]]; then
  resolve_ovftool
fi
if [[ "${SKIP_VM_START}" -eq 0 || "${SKIP_VERIFY}" -eq 0 ]]; then
  VMRUN_UNIX="$(to_unix_path "${VMRUN_WIN}")"
  [[ -f "${VMRUN_UNIX}" ]] || die "vmrun.exe not found: ${VMRUN_WIN}"
fi
if [[ -z "${VMRUN_UNIX}" ]]; then
  VMRUN_UNIX="$(to_unix_path "${VMRUN_WIN}" 2>/dev/null || true)"
  if [[ ! -f "${VMRUN_UNIX}" ]]; then
    VMRUN_UNIX=""
  fi
fi

log "Packer working dir (win): ${PACKER_DIR_WIN}"
log "Packer template (win): ${PACKER_TEMPLATE_WIN}"
log "Packer vars (win): ${PACKER_VARS_WIN}"

if [[ "${SKIP_PACKER_BUILD}" -eq 0 ]]; then
  if [[ -d "${OUTPUT_DIR_WSL}" ]]; then
    if [[ "${FORCE_BUILD}" -eq 1 ]]; then
      if [[ "${OUTPUT_DIR_WSL}" == "/" ]]; then
        die "Refusing to remove unsafe output directory: ${OUTPUT_DIR_WSL}"
      fi
      log "Removing existing packer output directory (--force): ${OUTPUT_DIR_WSL}"
      ps_run "if (Test-Path -LiteralPath '${OUTPUT_DIR_WIN}') { Remove-Item -LiteralPath '${OUTPUT_DIR_WIN}' -Recurse -Force }"
    else
      die "Packer output directory already exists: ${OUTPUT_DIR_WSL}. Remove it or rerun with --force."
    fi
  fi

  log "Packer cache dir (win): ${PACKER_CACHE_DIR_WIN}"
  log "Packer log path (win): ${PACKER_LOG_PATH_WIN}"
  PS_PACKER_ENV="\$env:PACKER_CACHE_DIR='${PACKER_CACHE_DIR_WIN}'; \$env:PACKER_LOG='1'; \$env:PACKER_LOG_PATH='${PACKER_LOG_PATH_WIN}';"
  ps_run "New-Item -ItemType Directory -Force -Path '${PACKER_CACHE_DIR_WIN}' | Out-Null; New-Item -ItemType Directory -Force -Path (Split-Path -Parent '${PACKER_LOG_PATH_WIN}') | Out-Null"
  if [[ "${FORCE_BUILD}" -eq 1 ]]; then
    FORCE_FLAG="-force"
  else
    FORCE_FLAG=""
  fi

  log "Running packer init (vmware plugin)"
  ps_run "${PS_PACKER_ENV} Set-Location -LiteralPath '${PACKER_DIR_WIN}'; & '${PACKER_EXE_WIN}' init '${PACKER_TEMPLATE_WIN}'"

  log "Running packer validate"
  ps_run "${PS_PACKER_ENV} Set-Location -LiteralPath '${PACKER_DIR_WIN}'; & '${PACKER_EXE_WIN}' validate -var-file '${PACKER_VARS_WIN}' '${PACKER_TEMPLATE_WIN}'"

  log "Running packer build (this can take a long time)"
  ps_run "${PS_PACKER_ENV} Set-Location -LiteralPath '${PACKER_DIR_WIN}'; & '${PACKER_EXE_WIN}' build ${FORCE_FLAG} -on-error=abort -var-file '${PACKER_VARS_WIN}' '${PACKER_TEMPLATE_WIN}'"
fi

[[ -f "${VMX_PATH}" ]] || die "VMX not found after build: ${VMX_PATH}"

if [[ "${SKIP_VM_START}" -eq 0 ]]; then
  if vm_is_running "${VMX_WIN}"; then
    log "VM is already running. Skipping vmrun start."
  else
    log "Starting VM with vmrun"
    ps_run "& '${VMRUN_WIN}' start '${VMX_WIN}' nogui"
  fi
fi

if [[ "${SKIP_VERIFY}" -eq 0 ]]; then
  log "Waiting for guest IP from VMware Tools"
  VM_IP="$(wait_for_vm_ip "${VMX_WIN}")" || die "Unable to resolve guest IP from vmrun getGuestIPAddress."
  log "Guest IP: ${VM_IP}"

  SSH_OPTS=(
    -p "${SSH_PORT}"
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=6
  )

  ssh_run() {
    SSHPASS="${VM_PASSWORD}" sshpass -e ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_IP}" "$@"
  }

  log "Waiting for SSH readiness"
  for attempt in $(seq 1 60); do
    if ssh_run "echo ready" >/dev/null 2>&1; then
      break
    fi
    sleep 5
    if [[ "${attempt}" -eq 60 ]]; then
      die "SSH did not become ready in time: ${VM_USER}@${VM_IP}:${SSH_PORT}"
    fi
  done

  log "Waiting for Kubernetes/services to become ready in VM"
  VERIFY_OK=0
  for attempt in $(seq 1 90); do
    if ssh_run "sudo bash /opt/k8s-data-platform/scripts/verify.sh --env '${ENVIRONMENT}' --http-mode nodeport --host 127.0.0.1 --http-timeout 5" >/tmp/vmware_verify.out 2>/tmp/vmware_verify.err; then
      VERIFY_OK=1
      break
    fi
    sleep 10
  done

  if [[ "${VERIFY_OK}" -ne 1 ]]; then
    log "Final verify stdout/stderr:"
    cat /tmp/vmware_verify.out || true
    cat /tmp/vmware_verify.err || true
    die "Kubernetes/pod verification failed in guest VM."
  fi

  log "Collecting final Kubernetes status"
  ssh_run "sudo bash /opt/k8s-data-platform/scripts/status_k8s.sh --env '${ENVIRONMENT}'"
  log "Verification completed successfully."
fi

if [[ "${SKIP_OVA_EXPORT}" -eq 0 ]]; then
  if [[ -n "${VMRUN_UNIX}" ]] && vm_is_running "${VMX_WIN}"; then
    log "Stopping running VM before OVA export"
    ps_run "& '${VMRUN_WIN}' stop '${VMX_WIN}' soft; if (\$LASTEXITCODE -ne 0) { & '${VMRUN_WIN}' stop '${VMX_WIN}' hard }"
  fi
  log "Exporting OVA with OVF Tool -> ${OVA_PATH}"
  ps_run "New-Item -ItemType Directory -Force -Path '${DIST_DIR_WIN}' | Out-Null; Remove-Item -LiteralPath '${OVA_WIN}' -Force -ErrorAction SilentlyContinue; & '${OVFTOOL_WIN}' --acceptAllEulas --skipManifestCheck '${VMX_WIN}' '${OVA_WIN}'"
  [[ -f "${OVA_PATH}" ]] || die "OVA export failed: ${OVA_PATH}"
fi

log "Done"
echo "VMX: ${VMX_PATH}"
echo "OVA: ${OVA_PATH}"
