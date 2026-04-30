#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="full"
EXTRA_INIT_ARGS=()

usage() {
  cat <<'EOF'
Usage: bash scripts/phase3_install_from_completed_ova.sh [mode] [init.sh options...]

Mode:
  full        import + vm-commands + route + hosts + start (default)
  continue    vm-commands + route + hosts + start (import skipped)
  import-only import + vm-commands only
  hosts-only  apply WSL/Windows hosts only
  start-only  start only

This script is a stage-3 wrapper for init.sh and forwards additional options
to init.sh unchanged.

Examples:
  bash scripts/phase3_install_from_completed_ova.sh full --ova-dir C:/ffmpeg
  bash scripts/phase3_install_from_completed_ova.sh continue --control-plane-ip 192.168.56.10
  bash scripts/phase3_install_from_completed_ova.sh start-only -- --skip-export --skip-nexus-prime
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    full|continue|import-only|hosts-only|start-only)
      MODE="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
  esac
fi

if [[ $# -gt 0 ]]; then
  EXTRA_INIT_ARGS=("$@")
fi

stage_args=()
case "${MODE}" in
  full)
    stage_args=(
      --import-ova
      --vm-commands
      --apply-wsl-route
      --apply-wsl-hosts
      --apply-windows-hosts
      --run-start
    )
    ;;
  continue)
    stage_args=(
      --vm-commands
      --apply-wsl-route
      --apply-wsl-hosts
      --apply-windows-hosts
      --run-start
    )
    ;;
  import-only)
    stage_args=(
      --import-ova
      --vm-commands
    )
    ;;
  hosts-only)
    stage_args=(
      --apply-wsl-hosts
      --apply-windows-hosts
    )
    ;;
  start-only)
    stage_args=(
      --run-start
    )
    ;;
  *)
    die "Unsupported mode: ${MODE}"
    ;;
esac

exec bash "${ROOT_DIR}/init.sh" "${stage_args[@]}" "${EXTRA_INIT_ARGS[@]}"

