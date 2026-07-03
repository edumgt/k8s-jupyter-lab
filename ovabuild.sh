#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.vmware.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"

usage() {
  cat <<'USAGE'
Usage: bash ovabuild.sh [options]

Options:
  --vars-file PATH   Packer vars file
  --dist-dir PATH    OVA output dir (Windows path allowed)
  --skip-sha256      Skip SHA256 generation
  -h, --help         Show help
USAGE
}

SKIP_SHA256=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file) PACKER_VARS="$2"; shift 2 ;;
    --dist-dir) DIST_DIR="$2"; shift 2 ;;
    --skip-sha256) SKIP_SHA256=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

bash "${ROOT_DIR}/scripts/vmware_export_3node_ova.sh" --vars-file "${PACKER_VARS}" --dist-dir "${DIST_DIR}"

if [[ "${SKIP_SHA256}" == "0" ]]; then
  if [[ "${DIST_DIR}" =~ ^[A-Za-z]:[\\/].* ]]; then
    DIST_UNIX="$(wslpath -u "${DIST_DIR}")"
  else
    DIST_UNIX="${DIST_DIR}"
  fi
  (cd "${DIST_UNIX}" && sha256sum *.ova > SHA256SUMS.txt)
  echo "SHA256SUMS.txt generated in ${DIST_DIR}"
fi
