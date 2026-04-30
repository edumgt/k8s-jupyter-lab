#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/k8s-data-platform/apps/frontend}"

usage() {
  cat <<'EOF'
Usage: bash scripts/run_frontend_build.sh [options]

Options:
  --app-dir <path>  Frontend application directory.
  -h, --help        Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      [[ $# -ge 2 ]] || die "--app-dir requires a value"
      APP_DIR="$2"
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

[[ -d "${APP_DIR}" ]] || die "Frontend app directory not found: ${APP_DIR}"
command -v npm >/dev/null 2>&1 || die "Required command not found: npm"

cd "${APP_DIR}"
exec npm run build
