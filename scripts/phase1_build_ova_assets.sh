#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="all"
DRY_RUN=0
PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.vmware.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"
APT_BUNDLE_DIR="${APT_BUNDLE_DIR:-${ROOT_DIR}/dist/apt-bundle}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/phase1_build_ova_assets.sh [mode] [options]

Mode:
  all          Build apt bundle + VMware OVA (default)
  bundle-only  Build apt bundle only
  ova-only     Build VMware OVA only

Options:
  --vars-file PATH       Packer vars file
  --dist-dir PATH        OVA output dir
  --apt-bundle-dir PATH  apt bundle output dir
  --dry-run              Print commands only
  -h, --help             Show help
USAGE
}

die(){ printf '%s\n' "$*" >&2; exit 1; }
run_cmd(){ if [[ "${DRY_RUN}" == "1" ]]; then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

if [[ $# -gt 0 ]]; then
  case "$1" in
    all|bundle-only|ova-only) MODE="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file) PACKER_VARS="$2"; shift 2 ;;
    --dist-dir) DIST_DIR="$2"; shift 2 ;;
    --apt-bundle-dir) APT_BUNDLE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "${MODE}" == "all" || "${MODE}" == "bundle-only" ]]; then
  run_cmd bash "${ROOT_DIR}/scripts/prepare_vm_apt_bundle.sh" --output-dir "${APT_BUNDLE_DIR}"
fi

if [[ "${MODE}" == "all" || "${MODE}" == "ova-only" ]]; then
  run_cmd bash "${ROOT_DIR}/scripts/build_vmware_ova_and_verify.sh" --vars-file "${PACKER_VARS}" --dist-dir "${DIST_DIR}"
fi
