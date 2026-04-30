#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXUS_URL="${NEXUS_URL:-http://127.0.0.1:30091}"
NEXUS_USERNAME="${NEXUS_USERNAME:-}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/nexus-prime}"
PYTHON_SEED_FILE="${PYTHON_SEED_FILE:-${ROOT_DIR}/scripts/offline/python-dev-seed.txt}"
NPM_SEED_FILE="${NPM_SEED_FILE:-${ROOT_DIR}/scripts/offline/npm-dev-seed.txt}"
SKIP_PYTHON_SEED=0
SKIP_NPM_SEED=0
SKIP_JUPYTER_REQUIREMENTS=0
SKIP_AIRFLOW_REQUIREMENTS=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/prime_nexus_caches.sh [options]

Options:
  --nexus-url <url>          Reachable Nexus base URL. Defaults to http://127.0.0.1:30091.
  --username <name>          Nexus repository username (optional).
  --password <pw>            Nexus repository password (optional).
  --out-dir <path>           Directory where warmed cache artifacts will be stored.
  --python-seed-file <path>  Extra pip seed list (requirements format).
                             Defaults to scripts/offline/python-dev-seed.txt.
  --npm-seed-file <path>     Extra npm seed list (one package@range per line).
                             Defaults to scripts/offline/npm-dev-seed.txt.
  --skip-python-seed         Skip extra Python dev seed warming.
  --skip-npm-seed            Skip extra npm dev seed warming.
  --skip-jupyter-requirements
                             Skip apps/jupyter/requirements.txt warming.
  --skip-airflow-requirements
                             Skip apps/airflow/requirements.txt warming.
  --dry-run                  Print commands without executing them.
  -h, --help                 Show this help.
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
  local url="$1"
  local scope="${url#http://}"
  scope="${scope#https://}"
  printf '%s' "${scope}"
}

write_npm_auth_config() {
  local file_path="$1"
  local registry_url="$2"
  local npm_scope="$3"
  local auth_b64

  if [[ -z "${NEXUS_USERNAME}" || -z "${NEXUS_PASSWORD}" ]]; then
    return 0
  fi

  auth_b64="$(printf '%s:%s' "${NEXUS_USERNAME}" "${NEXUS_PASSWORD}" | base64 | tr -d '\n')"
  {
    printf 'registry=%s\n' "${registry_url}"
    printf 'always-auth=true\n'
    printf '//%s:_auth=%s\n' "${npm_scope}" "${auth_b64}"
  } > "${file_path}"
}

download_python_requirements() {
  local app_name="$1"
  local requirements_file="$2"
  local index_url
  local shown_index_url
  local host_name="${NEXUS_URL#http://}"
  host_name="${host_name#https://}"
  host_name="${host_name%%/*}"
  host_name="${host_name%%:*}"
  index_url="$(index_url_with_auth "${NEXUS_URL}/repository/pypi-all/simple")"

  run_cmd mkdir -p "${OUT_DIR}/wheels/${app_name}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    shown_index_url="${NEXUS_URL}/repository/pypi-all/simple"
    if [[ -n "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
      shown_index_url="${shown_index_url} (auth)"
    fi
    printf '+ python3 -m pip download --dest %q --index-url %q --trusted-host %q --disable-pip-version-check -r %q\n' \
      "${OUT_DIR}/wheels/${app_name}" "${shown_index_url}" "${host_name}" "${requirements_file}"
    return 0
  fi
  run_cmd python3 -m pip download \
    --dest "${OUT_DIR}/wheels/${app_name}" \
    --index-url "${index_url}" \
    --trusted-host "${host_name}" \
    --disable-pip-version-check \
    -r "${requirements_file}"
}

prime_frontend_registry() {
  local cache_dir="${OUT_DIR}/npm-cache"
  local registry_url="${NEXUS_URL}/repository/npm-all/"
  local npm_scope
  local temp_dir

  npm_scope="$(registry_scope "${registry_url}")"

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ %q\n' "npm install --cache ${cache_dir} --ignore-scripts --registry ${registry_url}"
    if [[ -n "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
      printf '+ %q\n' "npm auth configured for //${npm_scope}"
    fi
    return 0
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "${temp_dir}"' RETURN

  mkdir -p "${cache_dir}" "${temp_dir}/home"
  cp "${ROOT_DIR}/apps/frontend/package.json" "${temp_dir}/package.json"
  write_npm_auth_config "${temp_dir}/home/.npmrc" "${registry_url}" "${npm_scope}"
  (
    cd "${temp_dir}"
    HOME="${temp_dir}/home" npm install --cache "${cache_dir}" --ignore-scripts --registry "${registry_url}"
  )
  cp "${temp_dir}/package-lock.json" "${OUT_DIR}/frontend-package-lock.json"
  rm -rf "${temp_dir}"
  trap - RETURN
}

download_python_seed_packages() {
  local seed_file="$1"
  local index_url
  local host_name

  [[ -f "${seed_file}" ]] || die "Python seed file not found: ${seed_file}"

  host_name="${NEXUS_URL#http://}"
  host_name="${host_name#https://}"
  host_name="${host_name%%/*}"
  host_name="${host_name%%:*}"
  index_url="$(index_url_with_auth "${NEXUS_URL}/repository/pypi-all/simple")"

  run_cmd mkdir -p "${OUT_DIR}/wheels/dev-seed"
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ python3 -m pip download --dest %q --index-url %q --trusted-host %q --disable-pip-version-check -r %q\n' \
      "${OUT_DIR}/wheels/dev-seed" "${NEXUS_URL}/repository/pypi-all/simple" "${host_name}" "${seed_file}"
    return 0
  fi

  run_cmd python3 -m pip download \
    --dest "${OUT_DIR}/wheels/dev-seed" \
    --index-url "${index_url}" \
    --trusted-host "${host_name}" \
    --disable-pip-version-check \
    -r "${seed_file}"
}

prime_npm_seed_packages() {
  local seed_file="$1"
  local registry_url="${NEXUS_URL}/repository/npm-all/"
  local npm_scope
  local cache_dir="${OUT_DIR}/npm-cache"
  local temp_dir
  local seed_packages=()

  [[ -f "${seed_file}" ]] || die "npm seed file not found: ${seed_file}"
  mapfile -t seed_packages < <(sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${seed_file}")
  if [[ "${#seed_packages[@]}" -eq 0 ]]; then
    return 0
  fi

  npm_scope="$(registry_scope "${registry_url}")"

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ npm install --cache %q --ignore-scripts --registry %q %s\n' \
      "${cache_dir}" "${registry_url}" "${seed_packages[*]}"
    return 0
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "${temp_dir}"' RETURN
  mkdir -p "${cache_dir}" "${temp_dir}/home"
  write_npm_auth_config "${temp_dir}/home/.npmrc" "${registry_url}" "${npm_scope}"

  (
    cd "${temp_dir}"
    HOME="${temp_dir}/home" npm install \
      --cache "${cache_dir}" \
      --ignore-scripts \
      --registry "${registry_url}" \
      "${seed_packages[@]}"
  )

  cp "${temp_dir}/package-lock.json" "${OUT_DIR}/npm-dev-seed-package-lock.json"
  rm -rf "${temp_dir}"
  trap - RETURN
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
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --python-seed-file)
      [[ $# -ge 2 ]] || die "--python-seed-file requires a value"
      PYTHON_SEED_FILE="$2"
      shift 2
      ;;
    --npm-seed-file)
      [[ $# -ge 2 ]] || die "--npm-seed-file requires a value"
      NPM_SEED_FILE="$2"
      shift 2
      ;;
    --skip-python-seed)
      SKIP_PYTHON_SEED=1
      shift
      ;;
    --skip-npm-seed)
      SKIP_NPM_SEED=1
      shift
      ;;
    --skip-jupyter-requirements)
      SKIP_JUPYTER_REQUIREMENTS=1
      shift
      ;;
    --skip-airflow-requirements)
      SKIP_AIRFLOW_REQUIREMENTS=1
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

require_command python3
require_command npm
require_command base64

if [[ -n "${NEXUS_USERNAME}" && -z "${NEXUS_PASSWORD}" ]]; then
  die "--username is set but --password is empty"
fi

if [[ -z "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
  die "--password is set but --username is empty"
fi

run_cmd mkdir -p "${OUT_DIR}"
download_python_requirements backend "${ROOT_DIR}/apps/backend/requirements.txt"
if [[ "${SKIP_JUPYTER_REQUIREMENTS}" != "1" ]]; then
  download_python_requirements jupyter "${ROOT_DIR}/apps/jupyter/requirements.txt"
fi
if [[ "${SKIP_AIRFLOW_REQUIREMENTS}" != "1" ]]; then
  download_python_requirements airflow "${ROOT_DIR}/apps/airflow/requirements.txt"
fi
if [[ "${SKIP_PYTHON_SEED}" != "1" ]]; then
  download_python_seed_packages "${PYTHON_SEED_FILE}"
fi
prime_frontend_registry
if [[ "${SKIP_NPM_SEED}" != "1" ]]; then
  prime_npm_seed_packages "${NPM_SEED_FILE}"
fi

printf 'Nexus caches warmed via %s\n' "${NEXUS_URL}"
