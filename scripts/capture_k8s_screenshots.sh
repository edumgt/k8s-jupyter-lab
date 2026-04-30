#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/docs/screenshots}"
PLAYWRIGHT_IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.58.2-jammy}"
PLAYWRIGHT_NPM_PACKAGE="${PLAYWRIGHT_NPM_PACKAGE:-playwright@1.58.2}"
DRY_RUN=0
ENV_VARS=(
  CAPTURE_TARGETS
  PLAYWRIGHT_IMAGE
  PLAYWRIGHT_NPM_PACKAGE
  FRONTEND_URL
  BACKEND_URL
  AIRFLOW_URL
  AIRFLOW_USERNAME
  AIRFLOW_PASSWORD
  JUPYTER_URL
  GITLAB_URL
  GITLAB_USERNAME
  GITLAB_PASSWORD
  GITLAB_ROOT_PASSWORD
  GITLAB_DEV1_USERNAME
  GITLAB_DEV1_PASSWORD
  GITLAB_DEV2_USERNAME
  GITLAB_DEV2_PASSWORD
  NEXUS_URL
  NEXUS_USERNAME
  NEXUS_PASSWORD
  BACKEND_GIT_FLOW_FILE
  FRONTEND_GIT_FLOW_FILE
  BROWSER_CDP_URL
  ADMIN_USERNAME
  ADMIN_PASSWORD
  CONTROL_PLANE_USERNAME
  CONTROL_PLANE_PASSWORD
  TEST1_USERNAME
  TEST1_PASSWORD
  TEST1_LAB_URL
  SCREENSHOT_SUFFIX
)

usage() {
  cat <<'EOF'
Usage: bash scripts/capture_k8s_screenshots.sh [options]

Options:
  --dry-run   Print the Playwright container command without executing it.
  -h, --help  Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

build_env_args() {
  local item
  for item in "${ENV_VARS[@]}"; do
    if [[ -n "${!item:-}" ]]; then
      DOCKER_ENV_ARGS+=(-e "${item}=${!item}")
    fi
  done
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

while [[ $# -gt 0 ]]; do
  case "$1" in
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

require_command docker
run_cmd mkdir -p "${OUTPUT_DIR}"
if [[ "${OUTPUT_DIR}" == "${ROOT_DIR}"/* ]]; then
  CONTAINER_OUTPUT_DIR="${CONTAINER_OUTPUT_DIR:-/workspace/${OUTPUT_DIR#${ROOT_DIR}/}}"
else
  CONTAINER_OUTPUT_DIR="${CONTAINER_OUTPUT_DIR:-/workspace/docs/screenshots}"
fi
DOCKER_ENV_ARGS=()
build_env_args

run_cmd docker run --rm \
  --network host \
  -v "${ROOT_DIR}:/workspace" \
  -w /workspace \
  -e "OUTPUT_DIR=${CONTAINER_OUTPUT_DIR}" \
  "${DOCKER_ENV_ARGS[@]}" \
  "${PLAYWRIGHT_IMAGE}" \
  bash -lc 'set -euo pipefail; created_link=0; temp_runner=""; module_dir=""; if [[ -d /opt/playwright-runner/node_modules/playwright ]]; then module_dir="/opt/playwright-runner/node_modules"; elif [[ -d /usr/lib/node_modules/playwright ]]; then module_dir="/usr/lib/node_modules"; else temp_runner="/tmp/playwright-runner"; rm -rf "${temp_runner}"; mkdir -p "${temp_runner}"; npm install --prefix "${temp_runner}" --no-save "${PLAYWRIGHT_NPM_PACKAGE}"; module_dir="${temp_runner}/node_modules"; fi; if [[ ! -e /workspace/node_modules && -n "${module_dir}" ]]; then ln -s "${module_dir}" /workspace/node_modules; created_link=1; fi; node scripts/playwright/capture.mjs; status=$?; if [[ "${created_link}" == "1" ]]; then rm -f /workspace/node_modules; fi; if [[ -n "${temp_runner}" ]]; then rm -rf "${temp_runner}"; fi; exit "${status}"'
