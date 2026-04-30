#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.pkr.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"
POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
EXPORTER="${EXPORTER:-auto}"
DEFAULT_VBOXMANAGE_WINDOWS="/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/build_ova.sh [options]

Options:
  --vars FILE              Override the packer variables file.
  --dist-dir DIR           Override the export output directory.
  --exporter NAME          One of: auto, vboxmanage, ovftool.
  --dry-run                Print the export command without running it.
  -h, --help               Show this help message.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

trim() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

resolve_from_root() {
  local path="$1"

  if [[ "${path}" = /* ]]; then
    printf '%s' "${path}"
    return
  fi

  printf '%s' "${ROOT_DIR}/${path}"
}

read_packer_var() {
  local key="$1"
  local value

  value="$(read_optional_packer_var "${key}")"
  [[ -n "${value}" ]] || die "Required setting not found or empty in ${PACKER_VARS}: ${key}"
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

is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]] && return 0
  grep -qi microsoft /proc/version 2>/dev/null
}

is_windows_style_path() {
  [[ "$1" =~ ^[A-Za-z]:[\\/].* ]]
}

is_windows_executable() {
  [[ "$1" =~ \.[Ee][Xx][Ee]$ ]]
}

require_wslpath() {
  command -v wslpath >/dev/null 2>&1 || die "wslpath is required to bridge WSL paths for Windows tools."
}

resolve_windows_tool_path() {
  local candidate="$1"

  [[ -n "${candidate}" ]] || return 1

  if command -v "${candidate}" >/dev/null 2>&1; then
    command -v "${candidate}"
    return 0
  fi

  if is_wsl && is_windows_style_path "${candidate}"; then
    require_wslpath
    candidate="$(wslpath -u "${candidate}")"
  fi

  [[ -f "${candidate}" ]] || return 1
  printf '%s' "${candidate}"
}

to_tool_arg() {
  local tool="$1"
  local path="$2"

  if is_wsl && is_windows_executable "${tool}" && [[ "${path}" = /* ]]; then
    require_wslpath
    wslpath -w "${path}"
    return 0
  fi

  printf '%s' "${path}"
}

normalize_root_path() {
  local path="$1"

  if is_wsl && is_windows_style_path "${path}"; then
    require_wslpath
    wslpath -u "${path}"
    return 0
  fi

  resolve_from_root "${path}"
}

resolve_output_directory() {
  local path="$1"

  if is_wsl && is_windows_style_path "${path}"; then
    require_wslpath
    wslpath -u "${path}"
    return 0
  fi

  if [[ "${path}" = /* ]]; then
    printf '%s' "${path}"
    return 0
  fi

  printf '%s' "${ROOT_DIR}/packer/${path}"
}

invoke_via_powershell() {
  command -v "${POWERSHELL_BIN}" >/dev/null 2>&1 || die "PowerShell not found: ${POWERSHELL_BIN}"

  local powershell_script
  powershell_script="$(to_tool_arg "${POWERSHELL_BIN}" "${ROOT_DIR}/scripts/export_ova.ps1")"

  run_cmd "${POWERSHELL_BIN}" \
    -NoProfile \
    -ExecutionPolicy Bypass \
    -File "${powershell_script}" \
    -VmName "${VM_NAME}" \
    -OutputDir "$(to_tool_arg "${POWERSHELL_BIN}" "${VMX_DIR}")" \
    -DistDir "$(to_tool_arg "${POWERSHELL_BIN}" "${DIST_DIR}")" \
    -Exporter "${EXPORTER}" \
    -VBoxManage "${VBOXMANAGE_TOOL}" \
    -OvfTool "${OVFTOOL}"
}

resolve_exporter_tools() {
  local ovftool_candidate
  local vboxmanage_candidate
  local packer_vboxmanage

  packer_vboxmanage="$(read_optional_packer_var vboxmanage_path_windows)"
  ovftool_candidate="${OVFTOOL_PATH:-$(read_optional_packer_var ovftool_path_windows)}"

  for vboxmanage_candidate in \
    "${VBOXMANAGE_PATH:-}" \
    "${packer_vboxmanage}" \
    "${DEFAULT_VBOXMANAGE_WINDOWS}" \
    "VBoxManage.exe" \
    "VBoxManage"
  do
    if VBOXMANAGE_TOOL="$(resolve_windows_tool_path "${vboxmanage_candidate}")"; then
      break
    fi
  done

  if [[ -n "${ovftool_candidate}" ]]; then
    OVFTOOL="$(resolve_windows_tool_path "${ovftool_candidate}" || true)"
  else
    OVFTOOL=""
  fi
}

run_vboxmanage_export() {
  [[ -n "${VBOXMANAGE_TOOL:-}" ]] || return 1
  run_cmd "${VBOXMANAGE_TOOL}" export "${VM_NAME}" --output "$(to_tool_arg "${VBOXMANAGE_TOOL}" "${OVA_PATH}")"
}

run_ovftool_export() {
  [[ -n "${OVFTOOL:-}" ]] || return 1
  [[ -f "${VMX_PATH}" ]] || die "VMX not found: ${VMX_PATH}"
  run_cmd "${OVFTOOL}" --acceptAllEulas --skipManifestCheck "$(to_tool_arg "${OVFTOOL}" "${VMX_PATH}")" "$(to_tool_arg "${OVFTOOL}" "${OVA_PATH}")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars)
      [[ $# -ge 2 ]] || die "--vars requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || die "--dist-dir requires a value"
      DIST_DIR="$2"
      shift 2
      ;;
    --exporter)
      [[ $# -ge 2 ]] || die "--exporter requires a value"
      EXPORTER="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

[[ -f "${PACKER_VARS}" ]] || die "packer variables file not found: ${PACKER_VARS}"
case "${EXPORTER}" in
  auto|vboxmanage|ovftool) ;;
  *) die "Unsupported exporter: ${EXPORTER}" ;;
esac

DIST_DIR="$(normalize_root_path "${DIST_DIR}")"
mkdir -p "${DIST_DIR}"

VM_NAME="${VM_NAME:-$(read_packer_var vm_name)}"
OUTPUT_DIR="${OUTPUT_DIR:-$(read_packer_var output_directory)}"

VMX_DIR="$(resolve_output_directory "${OUTPUT_DIR}")"

VMX_PATH="${VMX_DIR}/${VM_NAME}.vmx"
OVA_PATH="${DIST_DIR}/${VM_NAME}.ova"
VBOXMANAGE_TOOL=""
OVFTOOL=""
resolve_exporter_tools

if [[ "${EXPORTER}" == "vboxmanage" ]]; then
  run_vboxmanage_export || die "VBoxManage export failed for ${VM_NAME}"
  echo "OVA exported: ${OVA_PATH}"
  exit 0
fi

if [[ "${EXPORTER}" == "ovftool" ]]; then
  run_ovftool_export || die "OVF Tool export failed for ${VM_NAME}"
  echo "OVA exported: ${OVA_PATH}"
  exit 0
fi

if run_vboxmanage_export; then
  echo "OVA exported with VBoxManage: ${OVA_PATH}"
  exit 0
fi

if run_ovftool_export; then
  echo "OVA exported with OVF Tool: ${OVA_PATH}"
  exit 0
fi

if is_wsl; then
  echo "Direct OVA export failed. Retrying with PowerShell." >&2
  invoke_via_powershell
  echo "OVA exported: ${OVA_PATH}"
  exit 0
fi

die "OVA export failed: ${OVA_PATH}"
