#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXUS_URL="${NEXUS_URL:-http://127.0.0.1:30091}"
NEXUS_USERNAME="${NEXUS_USERNAME:-}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-}"
BACKEND_REQUIREMENTS="${BACKEND_REQUIREMENTS:-${ROOT_DIR}/apps/backend/requirements.txt}"
FRONTEND_PACKAGE_JSON="${FRONTEND_PACKAGE_JSON:-${ROOT_DIR}/apps/frontend/package.json}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/nexus-verify}"
SKIP_BACKEND=0
SKIP_FRONTEND=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/verify_nexus_dependencies.sh [options]

Options:
  --nexus-url <url>         Reachable Nexus base URL. Defaults to http://127.0.0.1:30091.
  --username <name>         Nexus repository username (optional).
  --password <pw>           Nexus repository password (optional).
  --backend-req <path>      Backend requirements file path.
  --frontend-package <path> Frontend package.json path.
  --out-dir <path>          Output directory for verification artifacts.
  --skip-backend            Skip backend verification.
  --skip-frontend           Skip frontend verification.
  --dry-run                 Print commands without executing.
  -h, --help                Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

urlencode() {
  python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

index_url_with_auth() {
  local base_url="$1"
  local scheme
  local remainder
  local user_enc
  local pass_enc

  if [[ -z "${NEXUS_USERNAME}" || -z "${NEXUS_PASSWORD}" ]]; then
    printf '%s' "${base_url}"
    return 0
  fi

  scheme="${base_url%%://*}"
  remainder="${base_url#*://}"
  user_enc="$(urlencode "${NEXUS_USERNAME}")"
  pass_enc="$(urlencode "${NEXUS_PASSWORD}")"
  printf '%s://%s:%s@%s' "${scheme}" "${user_enc}" "${pass_enc}" "${remainder}"
}

registry_scope() {
  local registry_url="$1"
  local scope="${registry_url#http://}"
  scope="${scope#https://}"
  printf '%s' "${scope}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nexus-url)
      [[ $# -ge 2 ]] || die "--nexus-url requires a value"
      NEXUS_URL="$2"
      shift 2
      ;;
    --username)
      [[ $# -ge 2 ]] || die "--username requires a value"
      NEXUS_USERNAME="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || die "--password requires a value"
      NEXUS_PASSWORD="$2"
      shift 2
      ;;
    --backend-req)
      [[ $# -ge 2 ]] || die "--backend-req requires a value"
      BACKEND_REQUIREMENTS="$2"
      shift 2
      ;;
    --frontend-package)
      [[ $# -ge 2 ]] || die "--frontend-package requires a value"
      FRONTEND_PACKAGE_JSON="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --skip-backend)
      SKIP_BACKEND=1
      shift
      ;;
    --skip-frontend)
      SKIP_FRONTEND=1
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

if [[ "${SKIP_BACKEND}" == "1" && "${SKIP_FRONTEND}" == "1" ]]; then
  die "Nothing to verify: both backend and frontend checks are skipped."
fi

if [[ -n "${NEXUS_USERNAME}" && -z "${NEXUS_PASSWORD}" ]]; then
  die "--username is set but --password is empty"
fi
if [[ -z "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
  die "--password is set but --username is empty"
fi

require_command curl
require_command python3
require_command npm
require_command base64

if [[ "${DRY_RUN}" == "1" ]]; then
  printf '+ mkdir -p %q\n' "${OUT_DIR}"
else
  mkdir -p "${OUT_DIR}"
fi

backend_failed=0
frontend_failed=0

if [[ "${SKIP_BACKEND}" != "1" ]]; then
  [[ -f "${BACKEND_REQUIREMENTS}" ]] || die "Backend requirements file not found: ${BACKEND_REQUIREMENTS}"
  backend_index_url="$(index_url_with_auth "${NEXUS_URL}/repository/pypi-all/simple")"
  shown_backend_index_url="${NEXUS_URL}/repository/pypi-all/simple"
  if [[ -n "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
    shown_backend_index_url="${shown_backend_index_url} (auth)"
  fi
  host_name="${NEXUS_URL#http://}"
  host_name="${host_name#https://}"
  host_name="${host_name%%/*}"
  host_name="${host_name%%:*}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ python3 -m pip download --dest %q --index-url %q --trusted-host %q -r %q\n' \
      "${OUT_DIR}/backend-wheels" "${shown_backend_index_url}" "${host_name}" "${BACKEND_REQUIREMENTS}"
  else
    rm -rf "${OUT_DIR}/backend-wheels"
    mkdir -p "${OUT_DIR}/backend-wheels"
    if ! python3 -m pip download \
      --dest "${OUT_DIR}/backend-wheels" \
      --index-url "${backend_index_url}" \
      --trusted-host "${host_name}" \
      --disable-pip-version-check \
      -r "${BACKEND_REQUIREMENTS}" > "${OUT_DIR}/backend.log" 2>&1; then
      backend_failed=1
    fi
  fi
fi

if [[ "${SKIP_FRONTEND}" != "1" ]]; then
  [[ -f "${FRONTEND_PACKAGE_JSON}" ]] || die "Frontend package.json not found: ${FRONTEND_PACKAGE_JSON}"
  frontend_registry="${NEXUS_URL}/repository/npm-all/"
  frontend_scope="$(registry_scope "${frontend_registry}")"

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ npm install --package-lock-only --ignore-scripts --registry %q\n' "${frontend_registry}"
  else
    temp_dir="$(mktemp -d)"
    trap 'rm -rf "${temp_dir}"' RETURN
    mkdir -p "${temp_dir}/home"
    cp "${FRONTEND_PACKAGE_JSON}" "${temp_dir}/package.json"

    if [[ -n "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
      auth_b64="$(printf '%s:%s' "${NEXUS_USERNAME}" "${NEXUS_PASSWORD}" | base64 | tr -d '\n')"
      {
        printf 'registry=%s\n' "${frontend_registry}"
        printf 'always-auth=true\n'
        printf '//%s:_auth=%s\n' "${frontend_scope}" "${auth_b64}"
      } > "${temp_dir}/home/.npmrc"
    fi

    if ! (
      cd "${temp_dir}"
      HOME="${temp_dir}/home" npm install --package-lock-only --ignore-scripts --registry "${frontend_registry}"
    ) > "${OUT_DIR}/frontend.log" 2>&1; then
      frontend_failed=1
    else
      cp "${temp_dir}/package-lock.json" "${OUT_DIR}/frontend-package-lock.json"
    fi
    rm -rf "${temp_dir}"
    trap - RETURN
  fi
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  exit 0
fi

if [[ "${backend_failed}" -eq 0 && "${frontend_failed}" -eq 0 ]]; then
  printf 'Nexus dependency verification succeeded.\n'
  exit 0
fi

if [[ "${backend_failed}" -ne 0 ]]; then
  printf '[backend] verification failed. See %s\n' "${OUT_DIR}/backend.log" >&2
fi
if [[ "${frontend_failed}" -ne 0 ]]; then
  printf '[frontend] verification failed. See %s\n' "${OUT_DIR}/frontend.log" >&2
fi
exit 1
