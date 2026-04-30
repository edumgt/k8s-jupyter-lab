#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"
PACKER_TEMPLATE="k8s-data-platform.pkr.hcl"
PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"
EXPORTER="${EXPORTER:-auto}"
PACKER_BIN="${PACKER_BIN:-packer}"
PACKER_CACHE_WIN_DIR="${PACKER_CACHE_WIN_DIR:-C:\\ffmpeg\\packer-cache}"
SKIP_EXPORT=0
DRY_RUN="${DRY_RUN:-0}"

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
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

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ (cd %q && ' "${dir}"
    printf '%q ' "$@"
    printf ')\n'
    return 0
  fi

  (
    cd "${dir}"
    "$@"
  )
}

usage() {
  cat <<'EOF'
Usage: bash scripts/run_wsl.sh [options]

Note:
  This script uses the VirtualBox-based template (k8s-data-platform.pkr.hcl).
  For VMware-first workflow, use:
    - scripts/vmware_build_vm.sh
    - scripts/vmware_verify_vm.sh
    - scripts/vmware_export_ova.sh

Options:
  --vars-file PATH      Use a specific Packer vars file.
  --exporter NAME       One of: auto, vboxmanage, ovftool.
  --skip-export         Skip the final OVA export step.
  --dry-run             Print the commands without executing them.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --exporter)
      [[ $# -ge 2 ]] || die "--exporter requires a value"
      EXPORTER="$2"
      shift 2
      ;;
    --skip-export)
      SKIP_EXPORT=1
      shift
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

[[ -f "${PACKER_VARS}" ]] || die "Packer vars file not found: ${PACKER_VARS}"
is_wsl || die "scripts/run_wsl.sh must be executed inside WSL."
require_command wslpath

if [[ "${DRY_RUN}" != "1" ]]; then
  resolve_packer_bin
fi

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

log "Running packer init"
run_in_dir "${PACKER_DIR}" "${PACKER_BIN}" init .

log "Running packer validate"
run_in_dir "${PACKER_DIR}" "${PACKER_BIN}" validate "-var-file=${PACKER_VARS}" "${PACKER_TEMPLATE}"

log "Running packer build"
run_in_dir "${PACKER_DIR}" "${PACKER_BIN}" build "-var-file=${PACKER_VARS}" "${PACKER_TEMPLATE}"

if [[ "${SKIP_EXPORT}" != "1" ]]; then
  log "Running OVA export"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ '
    printf '%q ' "PACKER_VARS=${PACKER_VARS}" "DIST_DIR=${DIST_DIR}" "EXPORTER=${EXPORTER}" "${ROOT_DIR}/scripts/build_ova.sh"
    printf '\n'
  else
    PACKER_VARS="${PACKER_VARS}" DIST_DIR="${DIST_DIR}" EXPORTER="${EXPORTER}" "${ROOT_DIR}/scripts/build_ova.sh"
  fi
fi

log "WSL run flow completed"
