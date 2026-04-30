#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"
PACKER_TEMPLATE="k8s-data-platform.pkr.hcl"
PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.auto.pkrvars.hcl}"
PACKER_BIN="${PACKER_BIN:-packer}"
OUTPUT_WIN_DIR="${OUTPUT_WIN_DIR:-C:\\ffmpeg}"
PACKER_CACHE_WIN_DIR="${PACKER_CACHE_WIN_DIR:-C:\\ffmpeg\\packer-cache}"
EXPORTER="${EXPORTER:-auto}"
SKIP_PACKER_BUILD=0

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/build_packer_artifacts.sh [options]

Build and export files for these targets:
  Packer -> VirtualBox -> OVA
  OVA -> QEMU/KVM -> qcow2
  OVA -> AWS VM Import -> raw disk + import JSON template

Outputs are written to C:\ffmpeg by default and existing files are overwritten.

Options:
  --vars-file PATH       Packer var file path (default: packer/variables.auto.pkrvars.hcl)
  --output-win-dir PATH  Windows output dir (default: C:\ffmpeg)
  --exporter NAME        One of: auto, vboxmanage, ovftool (default: auto)
  --skip-packer-build    Skip packer init/validate/build and reuse existing VM output
  -h, --help             Show this help message
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
  [[ -n "${value}" ]] || die "Required setting not found or empty in ${PACKER_VARS}: ${key}"
  printf '%s' "${value}"
}

resolve_packer_bin() {
  if command -v "${PACKER_BIN}" >/dev/null 2>&1; then
    return 0
  fi

  if command -v packer.exe >/dev/null 2>&1; then
    PACKER_BIN="packer.exe"
    return 0
  fi

  die "Required command not found: packer"
}

run_in_dir() {
  local dir="$1"
  shift
  (
    cd "${dir}"
    "$@"
  )
}

resolve_iso_local_path() {
  local iso_url="$1"
  local iso_path

  [[ "${iso_url}" == file://* ]] || die "iso_url must start with file://. current: ${iso_url}"
  iso_path="${iso_url#file://}"
  iso_path="${iso_path//%20/ }"

  if [[ "${iso_path}" =~ ^/[A-Za-z]:/ ]]; then
    iso_path="${iso_path:1}"
  fi

  if [[ "${iso_path}" =~ ^[A-Za-z]:/ ]]; then
    iso_path="$(wslpath -u "${iso_path}")"
  fi

  [[ -f "${iso_path}" ]] || die "ISO file not found: ${iso_path}"
  printf '%s' "${iso_path}"
}

extract_primary_vmdk() {
  local ova_path="$1"
  local temp_dir="$2"
  local vmdk_path

  tar -xf "${ova_path}" -C "${temp_dir}"

  vmdk_path="$(
    find "${temp_dir}" -type f -name '*.vmdk' -printf '%s\t%p\n' \
      | sort -nr \
      | head -n 1 \
      | cut -f2-
  )"
  [[ -n "${vmdk_path}" ]] || die "No VMDK found in OVA: ${ova_path}"
  printf '%s' "${vmdk_path}"
}

write_ami_import_template() {
  local file_path="$1"
  local vm_name="$2"
  local raw_filename="$3"

  cat > "${file_path}" <<EOF
[
  {
    "Description": "${vm_name} raw image import",
    "Format": "raw",
    "UserBucket": {
      "S3Bucket": "REPLACE_ME",
      "S3Key": "${raw_filename}"
    }
  }
]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --output-win-dir)
      [[ $# -ge 2 ]] || die "--output-win-dir requires a value"
      OUTPUT_WIN_DIR="$2"
      shift 2
      ;;
    --exporter)
      [[ $# -ge 2 ]] || die "--exporter requires a value"
      EXPORTER="$2"
      shift 2
      ;;
    --skip-packer-build)
      SKIP_PACKER_BUILD=1
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

is_wsl || die "This script must be executed inside WSL."
require_command wslpath
require_command tar
require_command qemu-img
require_command sha256sum
[[ -f "${PACKER_VARS}" ]] || die "Packer vars file not found: ${PACKER_VARS}"

case "${EXPORTER}" in
  auto|vboxmanage|ovftool) ;;
  *) die "Unsupported exporter: ${EXPORTER}" ;;
esac

resolve_packer_bin

OUTPUT_DIR_WSL="$(wslpath -u "${OUTPUT_WIN_DIR}")"
mkdir -p "${OUTPUT_DIR_WSL}"

PACKER_BIN_RESOLVED="$(command -v "${PACKER_BIN}" || true)"
if [[ -z "${PACKER_CACHE_DIR:-}" ]]; then
  if [[ "${PACKER_BIN_RESOLVED,,}" == *.exe ]]; then
    PACKER_CACHE_DIR="${PACKER_CACHE_WIN_DIR}"
  else
    PACKER_CACHE_DIR="$(wslpath -u "${PACKER_CACHE_WIN_DIR}")"
  fi
fi

if is_windows_style_path "${PACKER_CACHE_DIR}"; then
  mkdir -p "$(wslpath -u "${PACKER_CACHE_DIR}")"
else
  mkdir -p "${PACKER_CACHE_DIR}"
fi
export PACKER_CACHE_DIR
log "Using PACKER_CACHE_DIR=${PACKER_CACHE_DIR}"

VM_NAME="$(read_packer_var vm_name)"
ISO_URL="$(read_packer_var iso_url)"
ISO_SOURCE_PATH="$(resolve_iso_local_path "${ISO_URL}")"

OVA_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}.ova"
ISO_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}.iso"
QCOW2_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}.qcow2"
AMI_RAW_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}-ami.raw"
AMI_JSON_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}-ami-import.json"
CHECKSUM_PATH="${OUTPUT_DIR_WSL}/${VM_NAME}-artifacts.sha256"

if [[ "${SKIP_PACKER_BUILD}" -eq 0 ]]; then
  log "Running packer init"
  run_in_dir "${PACKER_DIR}" "${PACKER_BIN}" init .

  log "Running packer validate"
  run_in_dir "${PACKER_DIR}" "${PACKER_BIN}" validate "-var-file=${PACKER_VARS}" "${PACKER_TEMPLATE}"

  log "Running packer build"
  run_in_dir "${PACKER_DIR}" "${PACKER_BIN}" build "-var-file=${PACKER_VARS}" "${PACKER_TEMPLATE}"
else
  log "Skipping packer build (--skip-packer-build)"
fi

log "Exporting OVA to ${OUTPUT_WIN_DIR} (overwrite enabled)"
rm -f "${OVA_PATH}"
PACKER_VARS="${PACKER_VARS}" DIST_DIR="${OUTPUT_DIR_WSL}" EXPORTER="${EXPORTER}" "${ROOT_DIR}/scripts/build_ova.sh"
[[ -f "${OVA_PATH}" ]] || die "OVA export failed: ${OVA_PATH}"

log "Copying ISO to ${OUTPUT_WIN_DIR} (overwrite enabled)"
if [[ "${ISO_SOURCE_PATH}" != "${ISO_PATH}" ]]; then
  rm -f "${ISO_PATH}"
  cp -f "${ISO_SOURCE_PATH}" "${ISO_PATH}"
fi
[[ -f "${ISO_PATH}" ]] || die "ISO copy failed: ${ISO_PATH}"

log "Converting OVA -> qcow2/raw"
TEMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

PRIMARY_VMDK="$(extract_primary_vmdk "${OVA_PATH}" "${TEMP_DIR}")"

rm -f "${QCOW2_PATH}" "${AMI_RAW_PATH}" "${AMI_JSON_PATH}" "${CHECKSUM_PATH}"
qemu-img convert -f vmdk -O qcow2 "${PRIMARY_VMDK}" "${QCOW2_PATH}"
qemu-img convert -f vmdk -O raw "${PRIMARY_VMDK}" "${AMI_RAW_PATH}"

write_ami_import_template "${AMI_JSON_PATH}" "${VM_NAME}" "$(basename "${AMI_RAW_PATH}")"

(
  cd "${OUTPUT_DIR_WSL}"
  sha256sum \
    "$(basename "${OVA_PATH}")" \
    "$(basename "${ISO_PATH}")" \
    "$(basename "${QCOW2_PATH}")" \
    "$(basename "${AMI_RAW_PATH}")" \
    > "$(basename "${CHECKSUM_PATH}")"
)

log "Artifacts generated (all overwritten if already existed):"
log "  OVA      : $(wslpath -w "${OVA_PATH}")"
log "  ISO      : $(wslpath -w "${ISO_PATH}")"
log "  QCOW2    : $(wslpath -w "${QCOW2_PATH}")"
log "  AMI RAW  : $(wslpath -w "${AMI_RAW_PATH}")"
log "  AMI JSON : $(wslpath -w "${AMI_JSON_PATH}")"
log "  SHA256   : $(wslpath -w "${CHECKSUM_PATH}")"
