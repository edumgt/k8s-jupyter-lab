#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/kubernetes_runtime.sh
source "${SCRIPT_DIR}/lib/kubernetes_runtime.sh"

ENVIRONMENT="dev"
HTTP_MODE="ingress"
TARGET_HOST="${TARGET_HOST:-}"
LB_IP="${LB_IP:-}"
HTTP_TIMEOUT=10
SKIP_HTTP=0
STRICT_HARBOR_CHECK=0
SKIP_HARBOR_CHECK=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/verify.sh [options]

Options:
  --env <dev|prod>             Verify the selected environment. Defaults to dev.
  --http-mode <ingress|nodeport>
                               HTTP check mode. Defaults to ingress.
  --host <addr>                NodePort target host for --http-mode nodeport.
                               Defaults to 127.0.0.1 in nodeport mode.
  --lb-ip <ip>                 Force ingress checks through this IP with Host headers.
                               Useful before hosts file is configured.
  --http-timeout <n>           curl timeout in seconds. Defaults to 10.
  --strict-harbor-check        Fail when Harbor(NodePort 30092) check fails.
  --skip-harbor-check          Skip Harbor(NodePort 30092) check.
  --skip-http                  Skip endpoint checks.
  -h, --help                   Show this help.
USAGE
}

warn() {
  printf '%s\n' "$*" >&2
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --http-mode)
      [[ $# -ge 2 ]] || die "--http-mode requires a value"
      HTTP_MODE="${2,,}"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      TARGET_HOST="$2"
      shift 2
      ;;
    --lb-ip)
      [[ $# -ge 2 ]] || die "--lb-ip requires a value"
      LB_IP="$2"
      shift 2
      ;;
    --http-timeout)
      [[ $# -ge 2 ]] || die "--http-timeout requires a value"
      HTTP_TIMEOUT="$2"
      shift 2
      ;;
    --strict-harbor-check)
      STRICT_HARBOR_CHECK=1
      shift
      ;;
    --skip-harbor-check)
      SKIP_HARBOR_CHECK=1
      shift
      ;;
    --skip-http)
      SKIP_HTTP=1
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

case "${ENVIRONMENT}" in
  dev|prod) ;;
  *)
    die "Unsupported environment: ${ENVIRONMENT}"
    ;;
esac

case "${HTTP_MODE}" in
  ingress|nodeport) ;;
  *)
    die "Unsupported --http-mode: ${HTTP_MODE} (expected: ingress or nodeport)"
    ;;
esac

if [[ -z "${TARGET_HOST}" && "${HTTP_MODE}" == "nodeport" ]]; then
  TARGET_HOST="127.0.0.1"
fi

NAMESPACE="data-platform-${ENVIRONMENT}"

printf '[verify] checking container runtime services\n'
kubernetes_services_ready

printf '[verify] checking cluster node readiness\n'
run_kubectl get nodes --no-headers | grep -q ' Ready'

printf '[verify] checking platform pods in %s\n' "${NAMESPACE}"
run_kubectl get pods -n "${NAMESPACE}" --no-headers

printf '[verify] checking platform services in %s\n' "${NAMESPACE}"
run_kubectl get svc -n "${NAMESPACE}" --no-headers

printf '[verify] checking persistent volumes in %s\n' "${NAMESPACE}"
run_kubectl get pvc -n "${NAMESPACE}" --no-headers >/dev/null

if [[ "${SKIP_HTTP}" == "1" ]]; then
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "Required command not found: curl"

check_http() {
  local name="$1"
  local url="$2"
  local host_header="${3:-}"

  printf '[verify] %s -> %s\n' "${name}" "${url}"

  if [[ -n "${host_header}" ]]; then
    curl --silent --show-error --fail --location --max-time "${HTTP_TIMEOUT}" \
      -H "Host: ${host_header}" \
      --output /dev/null \
      "${url}"
    return
  fi

  curl --silent --show-error --fail --location --max-time "${HTTP_TIMEOUT}" \
    --output /dev/null \
    "${url}"
}

check_ingress() {
  local name="$1"
  local host="$2"
  local path="$3"

  if [[ -n "${LB_IP}" ]]; then
    check_http "${name}" "http://${LB_IP}${path}" "${host}"
    return
  fi

  check_http "${name}" "http://${host}${path}"
}

if [[ "${HTTP_MODE}" == "nodeport" ]]; then
  check_http "frontend" "http://${TARGET_HOST}:30080"
  check_http "backend" "http://${TARGET_HOST}:30081/docs"
  check_http "jupyter" "http://${TARGET_HOST}:30088/lab"
  check_http "gitlab" "http://${TARGET_HOST}:30089/users/sign_in"
  check_http "nexus" "http://${TARGET_HOST}:30091"
  if [[ "${SKIP_HARBOR_CHECK}" != "1" ]]; then
    if ! check_http "harbor" "http://${TARGET_HOST}:30092"; then
      if [[ "${STRICT_HARBOR_CHECK}" == "1" ]]; then
        die "Harbor NodePort health check failed (http://${TARGET_HOST}:30092)."
      fi
      warn "[verify] WARNING: Harbor NodePort health check failed (http://${TARGET_HOST}:30092). Continuing (non-strict mode)."
    fi
  fi
  check_http "code-server" "http://${TARGET_HOST}:30100"
  exit 0
fi

if [[ "${ENVIRONMENT}" == "dev" ]]; then
  check_ingress "frontend" "dev.platform.local" "/"
  check_ingress "backend" "dev-api.platform.local" "/docs"
  check_ingress "jupyter" "jupyter.platform.local" "/lab"
  check_ingress "gitlab" "gitlab.platform.local" "/users/sign_in"
  check_ingress "airflow" "airflow.platform.local" "/"
  check_ingress "nexus" "nexus.platform.local" "/"
  exit 0
fi

check_ingress "frontend" "www.platform.local" "/"
check_ingress "backend" "api.platform.local" "/docs"
