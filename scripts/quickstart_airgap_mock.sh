#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.airgap-mock.yml"
PROJECT_NAME="${AIRGAP_MOCK_PROJECT:-k8s-airgap-mock}"
HOST="${AIRGAP_MOCK_HOST:-127.0.0.1}"
WAIT_TIMEOUT="${AIRGAP_MOCK_WAIT_TIMEOUT:-300}"
ACTION="up"
SKIP_JUPYTER=0
NO_BUILD=0
DRY_RUN=0
REMOVE_VOLUMES=0
COMPOSE=(docker compose)

log() {
  printf '[airgap-mock] %s\n' "$*"
}

warn() {
  printf '[airgap-mock] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[airgap-mock] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/quickstart_airgap_mock.sh [up|down|status] [options]

Local air-gap mock. Does not import OVAs or install Kubernetes.

  bash scripts/quickstart_airgap_mock.sh

Options:
  up                           Build and start the mock (default)
  down                         Stop the mock
  status                       Check published endpoints
  --skip-jupyter               Do not start Jupyter
  --no-build                   Reuse existing images
  --dry-run                    Print the compose command and exit
  --volumes                    With down, also remove mock volumes
  --host HOST                  Host used for readiness checks (default: 127.0.0.1)
  --timeout SECONDS            Readiness timeout (default: 300)
  -h, --help                   Show this help

Published URLs:
  Frontend      http://127.0.0.1:30080
  Backend docs  http://127.0.0.1:30081/docs
  Jupyter       http://127.0.0.1:30088/lab?token=platform123
  Harbor mock   http://127.0.0.1:30083
  GitLab mock   http://127.0.0.1:30089
  Airflow mock  http://127.0.0.1:30090
  Nexus mock    http://127.0.0.1:30091
EOF
}

quote_cmd() {
  local part
  printf '%q' "$1"
  shift
  for part in "$@"; do
    printf ' %q' "${part}"
  done
  printf '\n'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    up|down|status)
      ACTION="$1"
      shift
      ;;
    --skip-jupyter)
      SKIP_JUPYTER=1
      shift
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --volumes)
      REMOVE_VOLUMES=1
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      HOST="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      WAIT_TIMEOUT="$2"
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

case "${ACTION}" in
  up|down|status) ;;
  *)
    die "Unsupported action: ${ACTION}"
    ;;
esac

if [[ "${REMOVE_VOLUMES}" -eq 1 && "${ACTION}" != "down" ]]; then
  die "--volumes is only valid with down"
fi

if [[ ! "${WAIT_TIMEOUT}" =~ ^[0-9]+$ ]]; then
  die "--timeout must be a non-negative integer"
fi

[[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"

services=(mongodb redis backend frontend edge-mocks)
if [[ "${SKIP_JUPYTER}" -eq 0 ]]; then
  services+=(jupyter)
fi

run_compose() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    quote_cmd "${COMPOSE[@]}" -f "${COMPOSE_FILE}" --project-name "${PROJECT_NAME}" "$@"
    return 0
  fi
  "${COMPOSE[@]}" -f "${COMPOSE_FILE}" --project-name "${PROJECT_NAME}" "$@"
}

load_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    die "docker compose is required"
  fi
  docker info >/dev/null 2>&1 || die "Docker daemon is not running"
}

http_code() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null || true
    return 0
  fi
  python3 - "${url}" <<'PY' || true
import sys
import urllib.error
import urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=5) as response:
        print(response.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
PY
}

http_body() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 "${url}"
    return
  fi
  python3 - "${url}" <<'PY'
import sys
import urllib.request
print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode("utf-8", "replace"))
PY
}

is_http_up() {
  local code="$1"
  [[ "${code}" == "200" || "${code}" == "302" || "${code}" == "303" ]]
}

check_endpoint() {
  local label="$1"
  local url="$2"
  local expect="$3"
  local code body
  code="$(http_code "${url}")"
  if ! is_http_up "${code}"; then
    printf 'down - %s %s (HTTP %s)\n' "${label}" "${url}" "${code:-none}"
    return 1
  fi
  if [[ "${expect}" == "status-ok" ]]; then
    body="$(http_body "${url}")" || body=""
    if ! printf '%s' "${body}" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
      printf 'down - %s %s (status is not ok)\n' "${label}" "${url}"
      return 1
    fi
  fi
  printf 'ok   - %s %s\n' "${label}" "${url}"
  return 0
}

endpoint_checks() {
  local include_jupyter="$1"
  printf '%s\n' \
    "backend|http://${HOST}:30081/healthz|status-ok" \
    "frontend|http://${HOST}:30080/|http" \
    "harbor-mock|http://${HOST}:30083/healthz|status-ok" \
    "gitlab-mock|http://${HOST}:30089/healthz|status-ok" \
    "airflow-mock|http://${HOST}:30090/healthz|status-ok" \
    "nexus-mock|http://${HOST}:30091/healthz|status-ok"
  if [[ "${include_jupyter}" -eq 1 ]]; then
    printf '%s\n' "jupyter|http://${HOST}:30088/lab|http"
  fi
}

wait_ready() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local entry label url expect
  local -a pending=()
  local -a still=()
  while IFS= read -r entry; do
    pending+=("${entry}")
  done < <(endpoint_checks $((1 - SKIP_JUPYTER)))

  while (( ${#pending[@]} > 0 )); do
    still=()
    for entry in "${pending[@]}"; do
      IFS='|' read -r label url expect <<<"${entry}"
      if check_endpoint "${label}" "${url}" "${expect}" >/dev/null; then
        log "ready ${label} ${url}"
      else
        still+=("${entry}")
      fi
    done
    if (( ${#still[@]} == 0 )); then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      warn "timed out after ${WAIT_TIMEOUT}s"
      run_compose logs --tail 80 backend frontend mongodb redis jupyter edge-mocks >&2 || true
      for entry in "${still[@]}"; do
        IFS='|' read -r label url expect <<<"${entry}"
        check_endpoint "${label}" "${url}" "${expect}" || true
      done
      die "air-gap mock did not become ready"
    fi
    pending=()
    for entry in "${still[@]}"; do
      pending+=("${entry}")
    done
    sleep 2
  done
}

print_urls() {
  cat <<EOF
Air-gap mock is up. This is a local demo, not the OVA install.

  Frontend      http://${HOST}:30080
  Backend docs  http://${HOST}:30081/docs
  Demo login    admin@test.com / 123456
EOF
  if [[ "${SKIP_JUPYTER}" -eq 0 ]]; then
    printf '  Jupyter       http://%s:30088/lab?token=platform123\n' "${HOST}"
  fi
  cat <<EOF
  Harbor mock   http://${HOST}:30083
  GitLab mock   http://${HOST}:30089
  Airflow mock  http://${HOST}:30090
  Nexus mock    http://${HOST}:30091

Stop: bash scripts/quickstart_airgap_mock.sh down
EOF
}

if [[ "${DRY_RUN}" -eq 0 ]]; then
  load_compose
fi

case "${ACTION}" in
  up)
    up_args=(up -d)
    if [[ "${NO_BUILD}" -eq 0 ]]; then
      up_args+=(--build)
    fi
    up_args+=("${services[@]}")
    run_compose "${up_args[@]}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      exit 0
    fi
    if [[ "${SKIP_JUPYTER}" -eq 1 ]]; then
      run_compose stop jupyter >/dev/null 2>&1 || true
      run_compose rm -f jupyter >/dev/null 2>&1 || true
    fi
    wait_ready
    print_urls
    ;;
  down)
    down_args=(down --remove-orphans)
    if [[ "${REMOVE_VOLUMES}" -eq 1 ]]; then
      down_args+=(--volumes)
    fi
    run_compose "${down_args[@]}"
    ;;
  status)
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      run_compose ps
      exit 0
    fi
    run_compose ps || true
    failed=0
    while IFS= read -r entry; do
      IFS='|' read -r label url expect <<<"${entry}"
      check_endpoint "${label}" "${url}" "${expect}" || failed=1
    done < <(endpoint_checks $((1 - SKIP_JUPYTER)))
    exit "${failed}"
    ;;
esac
