#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ENV="${APP_ENV:-dev}"
NEXUS_URL="${NEXUS_URL:-http://127.0.0.1:30091}"
NEXUS_USERNAME="${NEXUS_USERNAME:-}"
NEXUS_PASSWORD="${NEXUS_PASSWORD:-}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/nexus-prime}"
BACKEND_ENV_FILE=""
FRONTEND_ENV_FILE=""
PYTHON_SEED_FILE=""
NPM_SEED_FILE=""
SKIP_PYTHON_SEED=0
SKIP_NPM_SEED=0
SKIP_JUPYTER_REQUIREMENTS=0
SKIP_AIRFLOW_REQUIREMENTS=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/prime_nexus_from_env.sh [options]

Options:
  --env <dev|prod>             Target environment. Defaults to dev.
  --backend-env-file <path>    Backend env file. Defaults to apps/backend/.env.<env>.
  --frontend-env-file <path>   Frontend env file. Defaults to apps/frontend/.env.<env>.
  --nexus-url <url>            Reachable Nexus base URL.
  --username <name>            Nexus repository username (optional).
  --password <pw>              Nexus repository password (optional).
  --out-dir <path>             Output directory for warmed cache artifacts.
  --python-seed-file <path>    Force Python seed file path (overrides env file).
  --npm-seed-file <path>       Force npm seed file path (overrides env file).
  --skip-python-seed           Skip Python seed warming.
  --skip-npm-seed              Skip npm seed warming.
  --skip-jupyter-requirements  Skip apps/jupyter requirements warming.
  --skip-airflow-requirements  Skip apps/airflow requirements warming.
  --dry-run                    Print commands without executing them.
  -h, --help                   Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

resolve_path() {
  local raw_path="$1"
  if [[ -z "${raw_path}" ]]; then
    return 0
  fi
  if [[ "${raw_path}" = /* ]]; then
    printf '%s' "${raw_path}"
    return 0
  fi
  printf '%s/%s' "${ROOT_DIR}" "${raw_path}"
}

read_env_value() {
  local file_path="$1"
  local key="$2"
  [[ -f "${file_path}" ]] || return 0
  awk -F '=' -v target="${key}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      k=$1
      sub(/^[[:space:]]+/, "", k)
      sub(/[[:space:]]+$/, "", k)
      if (k != target) next
      v=substr($0, index($0, "=")+1)
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      gsub(/^"/, "", v)
      gsub(/"$/, "", v)
      gsub(/^'\''/, "", v)
      gsub(/'\''$/, "", v)
      print v
      exit
    }
  ' "${file_path}"
}

append_extra_list() {
  local output_file="$1"
  local raw_list="$2"
  local item
  local normalized

  [[ -n "${raw_list}" ]] || return 0
  IFS=',' read -r -a items <<< "${raw_list}"
  for item in "${items[@]}"; do
    normalized="$(printf '%s' "${item}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "${normalized}" ]] || continue
    printf '%s\n' "${normalized}" >> "${output_file}"
  done
}

build_seed_file() {
  local base_file="$1"
  local extra_list="$2"
  local output_file="$3"

  : > "${output_file}"
  if [[ -n "${base_file}" ]]; then
    [[ -f "${base_file}" ]] || die "Seed file not found: ${base_file}"
    cat "${base_file}" >> "${output_file}"
    printf '\n' >> "${output_file}"
  fi
  append_extra_list "${output_file}" "${extra_list}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      APP_ENV="$2"
      shift 2
      ;;
    --backend-env-file)
      [[ $# -ge 2 ]] || die "--backend-env-file requires a value"
      BACKEND_ENV_FILE="$2"
      shift 2
      ;;
    --frontend-env-file)
      [[ $# -ge 2 ]] || die "--frontend-env-file requires a value"
      FRONTEND_ENV_FILE="$2"
      shift 2
      ;;
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

case "${APP_ENV}" in
  dev|prod) ;;
  *)
    die "--env must be dev or prod: ${APP_ENV}"
    ;;
esac

if [[ -n "${NEXUS_USERNAME}" && -z "${NEXUS_PASSWORD}" ]]; then
  die "--username is set but --password is empty"
fi
if [[ -z "${NEXUS_USERNAME}" && -n "${NEXUS_PASSWORD}" ]]; then
  die "--password is set but --username is empty"
fi

if [[ -z "${BACKEND_ENV_FILE}" ]]; then
  BACKEND_ENV_FILE="${ROOT_DIR}/apps/backend/.env.${APP_ENV}"
else
  BACKEND_ENV_FILE="$(resolve_path "${BACKEND_ENV_FILE}")"
fi
if [[ -z "${FRONTEND_ENV_FILE}" ]]; then
  FRONTEND_ENV_FILE="${ROOT_DIR}/apps/frontend/.env.${APP_ENV}"
else
  FRONTEND_ENV_FILE="$(resolve_path "${FRONTEND_ENV_FILE}")"
fi
[[ -f "${BACKEND_ENV_FILE}" ]] || die "Backend env file not found: ${BACKEND_ENV_FILE}"
[[ -f "${FRONTEND_ENV_FILE}" ]] || die "Frontend env file not found: ${FRONTEND_ENV_FILE}"

if [[ -z "${PYTHON_SEED_FILE}" ]]; then
  PYTHON_SEED_FILE="$(read_env_value "${BACKEND_ENV_FILE}" "NEXUS_PYTHON_SEED_FILE")"
fi
if [[ -z "${NPM_SEED_FILE}" ]]; then
  NPM_SEED_FILE="$(read_env_value "${FRONTEND_ENV_FILE}" "NEXUS_NPM_SEED_FILE")"
fi

if [[ -z "${PYTHON_SEED_FILE}" ]]; then
  PYTHON_SEED_FILE="${ROOT_DIR}/scripts/offline/python-${APP_ENV}-seed.txt"
else
  PYTHON_SEED_FILE="$(resolve_path "${PYTHON_SEED_FILE}")"
fi
if [[ -z "${NPM_SEED_FILE}" ]]; then
  NPM_SEED_FILE="${ROOT_DIR}/scripts/offline/npm-${APP_ENV}-seed.txt"
else
  NPM_SEED_FILE="$(resolve_path "${NPM_SEED_FILE}")"
fi

PYTHON_EXTRA_PACKAGES="$(read_env_value "${BACKEND_ENV_FILE}" "NEXUS_PYTHON_EXTRA_PACKAGES")"
NPM_EXTRA_PACKAGES="$(read_env_value "${FRONTEND_ENV_FILE}" "NEXUS_NPM_EXTRA_PACKAGES")"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
MERGED_PYTHON_SEED="${TMP_DIR}/python-seed.txt"
MERGED_NPM_SEED="${TMP_DIR}/npm-seed.txt"

build_seed_file "${PYTHON_SEED_FILE}" "${PYTHON_EXTRA_PACKAGES}" "${MERGED_PYTHON_SEED}"
build_seed_file "${NPM_SEED_FILE}" "${NPM_EXTRA_PACKAGES}" "${MERGED_NPM_SEED}"

prime_cmd=(
  bash "${ROOT_DIR}/scripts/prime_nexus_caches.sh"
  --nexus-url "${NEXUS_URL}"
  --out-dir "${OUT_DIR}"
  --python-seed-file "${MERGED_PYTHON_SEED}"
  --npm-seed-file "${MERGED_NPM_SEED}"
)
if [[ -n "${NEXUS_USERNAME}" ]]; then
  prime_cmd+=(--username "${NEXUS_USERNAME}")
fi
if [[ -n "${NEXUS_PASSWORD}" ]]; then
  prime_cmd+=(--password "${NEXUS_PASSWORD}")
fi
if [[ "${SKIP_PYTHON_SEED}" == "1" ]]; then
  prime_cmd+=(--skip-python-seed)
fi
if [[ "${SKIP_NPM_SEED}" == "1" ]]; then
  prime_cmd+=(--skip-npm-seed)
fi
if [[ "${SKIP_JUPYTER_REQUIREMENTS}" == "1" ]]; then
  prime_cmd+=(--skip-jupyter-requirements)
fi
if [[ "${SKIP_AIRFLOW_REQUIREMENTS}" == "1" ]]; then
  prime_cmd+=(--skip-airflow-requirements)
fi
if [[ "${DRY_RUN}" == "1" ]]; then
  prime_cmd+=(--dry-run)
fi

"${prime_cmd[@]}"
