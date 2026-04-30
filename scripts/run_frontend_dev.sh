#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/k8s-data-platform/apps/frontend}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-31080}"
API_BASE_URL="${VITE_API_BASE_URL:-http://platform.local}"

usage() {
  cat <<'EOF'
Usage: bash scripts/run_frontend_dev.sh [options]

Options:
  --app-dir <path>  Frontend application directory.
  --host <addr>     Bind address. Defaults to 0.0.0.0.
  --port <port>     Vite development port. Defaults to 31080.
  --api-base <url>  VITE_API_BASE_URL value for the dev server.
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
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      HOST="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      PORT="$2"
      shift 2
      ;;
    --api-base)
      [[ $# -ge 2 ]] || die "--api-base requires a value"
      API_BASE_URL="$2"
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
export VITE_API_BASE_URL="${API_BASE_URL}"
exec npm run dev -- --host "${HOST}" --port "${PORT}" --strictPort
