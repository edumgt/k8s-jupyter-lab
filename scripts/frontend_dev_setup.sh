#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/k8s-data-platform/apps/frontend}"
CACHE_DIR="${CACHE_DIR:-/opt/k8s-data-platform/offline-bundle/npm-cache}"
NPM_REGISTRY="${NPM_REGISTRY:-http://127.0.0.1:30091/repository/npm-group/}"
NPM_USERNAME="${NPM_USERNAME:-}"
NPM_PASSWORD="${NPM_PASSWORD:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/frontend_dev_setup.sh [options]

Options:
  --app-dir <path>      Frontend application directory.
  --cache-dir <path>    Offline npm cache directory.
  --registry <url>      Preferred Nexus npm registry URL.
  --username <name>     Nexus npm username (optional).
  --password <pw>       Nexus npm password (optional).
  --dry-run             Print commands without executing them.
  -h, --help            Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

registry_scope() {
  local scope="${NPM_REGISTRY#http://}"
  scope="${scope#https://}"
  printf '%s' "${scope}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-dir)
      [[ $# -ge 2 ]] || die "--app-dir requires a value"
      APP_DIR="$2"
      shift 2
      ;;
    --cache-dir)
      [[ $# -ge 2 ]] || die "--cache-dir requires a value"
      CACHE_DIR="$2"
      shift 2
      ;;
    --registry)
      [[ $# -ge 2 ]] || die "--registry requires a value"
      NPM_REGISTRY="$2"
      shift 2
      ;;
    --username)
      [[ $# -ge 2 ]] || die "--username requires a value"
      NPM_USERNAME="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "--password requires a value"
      NPM_PASSWORD="$2"
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

require_command npm
require_command base64
[[ -d "${APP_DIR}" ]] || die "Frontend app directory not found: ${APP_DIR}"

if [[ -n "${NPM_USERNAME}" && -z "${NPM_PASSWORD}" ]]; then
  die "--username is set but --password is empty"
fi
if [[ -z "${NPM_USERNAME}" && -n "${NPM_PASSWORD}" ]]; then
  die "--password is set but --username is empty"
fi

run_cmd mkdir -p "${CACHE_DIR}"

if [[ "${DRY_RUN}" == "1" ]]; then
  printf '+ (cd %q && npm config set registry %q)\n' "${APP_DIR}" "${NPM_REGISTRY}"
  if [[ -n "${NPM_USERNAME}" && -n "${NPM_PASSWORD}" ]]; then
    printf '+ (cd %q && npm config set always-auth true)\n' "${APP_DIR}"
    printf '+ (cd %q && npm config set %q %q)\n' "${APP_DIR}" "//$(registry_scope):_auth" "***redacted***"
  fi
  printf '+ (cd %q && npm install --cache %q --prefer-offline)\n' "${APP_DIR}" "${CACHE_DIR}"
  printf '+ (cd %q && npm install --cache %q --offline)\n' "${APP_DIR}" "${CACHE_DIR}"
  exit 0
fi

(
  npm_auth=""
  cd "${APP_DIR}"
  npm config set registry "${NPM_REGISTRY}"
  if [[ -n "${NPM_USERNAME}" && -n "${NPM_PASSWORD}" ]]; then
    npm_auth="$(printf '%s:%s' "${NPM_USERNAME}" "${NPM_PASSWORD}" | base64 | tr -d '\n')"
    npm config set always-auth true
    npm config set "//$(registry_scope):_auth" "${npm_auth}"
  fi
  if npm install --cache "${CACHE_DIR}" --prefer-offline; then
    exit 0
  fi

  printf '[frontend_dev_setup] Nexus install failed, retrying with offline cache only.\n' >&2
  npm install --cache "${CACHE_DIR}" --offline
)
