#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="full"
BUNDLE_DIR="${BUNDLE_DIR:-/opt/k8s-data-platform/offline-bundle}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/phase3_install_from_completed_ova.sh [mode] [options]

Mode:
  full         import + base install + check (default)
  import-only  import/apply offline bundle only
  install-only apply base stack only
  check-only   status checks only

Options:
  --bundle-dir PATH  Offline bundle path
  --dry-run          Print commands only
  -h, --help         Show help
USAGE
}

die(){ printf '%s\n' "$*" >&2; exit 1; }
run_cmd(){ if [[ "${DRY_RUN}" == "1" ]]; then printf '+'; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }

if [[ $# -gt 0 ]]; then
  case "$1" in
    full|import-only|install-only|check-only) MODE="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

run_import(){ run_cmd bash "${ROOT_DIR}/scripts/import_offline_bundle.sh" --bundle-dir "${BUNDLE_DIR}" --apply; }
run_install(){ run_cmd bash "${ROOT_DIR}/scripts/setup_k8s_modern_stack.sh"; }
run_check(){ run_cmd bash "${ROOT_DIR}/scripts/status_k8s.sh"; run_cmd bash "${ROOT_DIR}/scripts/check_vm_airgap_status.sh"; }

case "${MODE}" in
  full) run_import; run_install; run_check ;;
  import-only) run_import ;;
  install-only) run_install ;;
  check-only) run_check ;;
  *) die "Unsupported mode: ${MODE}" ;;
esac
