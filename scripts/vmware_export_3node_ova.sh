#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
PACKER_TEMPLATE="${PACKER_TEMPLATE:-${PACKER_DIR}/k8s-data-platform-vmware.pkr.hcl}"

CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-data-platform}"
WORKER1_NAME="${WORKER1_NAME:-k8s-worker-1}"
WORKER2_NAME="${WORKER2_NAME:-k8s-worker-2}"
WORKER3_NAME="${WORKER3_NAME:-k8s-worker-3}"

DIST_DIR=""
VMRUN_WIN="${VMRUN_WIN:-}"
OVFTOOL_WIN="${OVFTOOL_WIN:-}"
PACKER_EXE_WIN="${PACKER_EXE_WIN:-}"

RUNTIME_DIR=""

usage() {
  cat <<'EOF'
Usage: bash scripts/vmware_export_3node_ova.sh [options]

Exports 4 VMware VMs to OVA sequentially:
  control-plane, worker-1, worker-2, worker-3

Options:
  --vars-file PATH          Base vars file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --template PATH           Packer template (default: packer/k8s-data-platform-vmware.pkr.hcl)
  --dist-dir PATH           OVA output dir (default follows vmware_export_ova.sh default)
  --control-plane-name NAME (default: k8s-data-platform)
  --worker1-name NAME       (default: k8s-worker-1)
  --worker2-name NAME       (default: k8s-worker-2)
  --worker3-name NAME       (default: k8s-worker-3)
  --vmrun PATH              Optional vmrun.exe path
  --ovftool PATH            Optional ovftool.exe path
  --packer-exe PATH         Optional packer.exe path
  -h, --help                Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
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
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        gsub(/^"|"$/, "", $0)
        print $0
        exit
      }
    ' "${vars_file}"
  )"
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

resolve_output_dir_unix() {
  local output_dir_raw="$1"
  if is_windows_style_path "${output_dir_raw}"; then
    to_unix_path "${output_dir_raw}"
    return 0
  fi
  if [[ "${output_dir_raw}" = /* ]]; then
    printf '%s' "${output_dir_raw}"
    return 0
  fi
  printf '%s' "${PACKER_DIR}/${output_dir_raw}"
}

write_export_vars_file() {
  local base_file="$1"
  local out_file="$2"
  local vm_name="$3"
  local output_directory_override="$4"

  awk -v vm_name="${vm_name}" -v output_dir="${output_directory_override}" '
    BEGIN { replaced_vm_name=0; replaced_output_dir=0 }
    /^[[:space:]]*vm_name[[:space:]]*=/ {
      print "vm_name                   = \"" vm_name "\""
      replaced_vm_name=1
      next
    }
    /^[[:space:]]*output_directory[[:space:]]*=/ {
      if (output_dir != "") {
        print "output_directory          = \"" output_dir "\""
        replaced_output_dir=1
        next
      }
      print
      next
    }
    { print }
    END {
      if (!replaced_vm_name) {
        print "vm_name = \"" vm_name "\""
      }
      if (output_dir != "" && !replaced_output_dir) {
        print "output_directory = \"" output_dir "\""
      }
    }
  ' "${base_file}" > "${out_file}"
}

cleanup() {
  if [[ -n "${RUNTIME_DIR}" && -d "${RUNTIME_DIR}" ]]; then
    rm -rf "${RUNTIME_DIR}"
  fi
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
    --ovftool)
      [[ $# -ge 2 ]] || die "--ovftool requires a value"
      OVFTOOL_WIN="$2"
      shift 2
      ;;
    --packer-exe)
      [[ $# -ge 2 ]] || die "--packer-exe requires a value"
      PACKER_EXE_WIN="$2"
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

if is_windows_style_path "${PACKER_VARS}"; then
  PACKER_VARS="$(to_unix_path "${PACKER_VARS}")"
fi
if is_windows_style_path "${PACKER_TEMPLATE}"; then
  PACKER_TEMPLATE="$(to_unix_path "${PACKER_TEMPLATE}")"
fi
[[ -f "${PACKER_VARS}" ]] || die "Packer var file not found: ${PACKER_VARS}"
[[ -f "${PACKER_TEMPLATE}" ]] || die "Packer template not found: ${PACKER_TEMPLATE}"

RUNTIME_DIR="$(mktemp -d)"
trap cleanup EXIT

export_one() {
  local vm_name="$1"
  local vars_file="${RUNTIME_DIR}/${vm_name}.auto.pkrvars.hcl"
  local base_output_dir_raw
  local base_output_dir_unix
  local vmx_root
  local vmx_subdir
  local output_dir_override=""
  local output_dir_trimmed
  local cmd

  base_output_dir_raw="$(read_packer_var "${PACKER_VARS}" output_directory)"
  base_output_dir_unix="$(resolve_output_dir_unix "${base_output_dir_raw}")"
  vmx_root="${base_output_dir_unix}/${vm_name}.vmx"
  vmx_subdir="${base_output_dir_unix}/${vm_name}/${vm_name}.vmx"

  if [[ -f "${vmx_subdir}" ]]; then
    output_dir_trimmed="${base_output_dir_raw%/}"
    output_dir_trimmed="${output_dir_trimmed%\\}"
    output_dir_override="${output_dir_trimmed}/${vm_name}"
    log "Using worker VMX subdir layout for ${vm_name}: output_directory=${output_dir_override}"
  elif [[ -f "${vmx_root}" ]]; then
    :
  else
    die "VMX not found for ${vm_name}. Checked: ${vmx_root} and ${vmx_subdir}"
  fi

  write_export_vars_file "${PACKER_VARS}" "${vars_file}" "${vm_name}" "${output_dir_override}"

  cmd=(bash "${ROOT_DIR}/scripts/vmware_export_ova.sh" --vars-file "${vars_file}" --template "${PACKER_TEMPLATE}")
  if [[ -n "${DIST_DIR}" ]]; then
    cmd+=(--dist-dir "${DIST_DIR}")
  fi
  if [[ -n "${VMRUN_WIN}" ]]; then
    cmd+=(--vmrun "${VMRUN_WIN}")
  fi
  if [[ -n "${OVFTOOL_WIN}" ]]; then
    cmd+=(--ovftool "${OVFTOOL_WIN}")
  fi
  if [[ -n "${PACKER_EXE_WIN}" ]]; then
    cmd+=(--packer-exe "${PACKER_EXE_WIN}")
  fi

  log "Exporting OVA for ${vm_name}"
  "${cmd[@]}"
}

export_one "${CONTROL_PLANE_NAME}"
export_one "${WORKER1_NAME}"
export_one "${WORKER2_NAME}"
export_one "${WORKER3_NAME}"

log "All 4 OVA exports completed."
