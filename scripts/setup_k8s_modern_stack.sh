#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

METALLB_RANGE="${METALLB_RANGE:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
METALLB_MANIFEST="${METALLB_MANIFEST:-}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-}"
METRICS_SERVER_MANIFEST="${METRICS_SERVER_MANIFEST:-}"
HEADLAMP_MANIFEST="${HEADLAMP_MANIFEST:-}"
HEADLAMP_INGRESS_HOST="${HEADLAMP_INGRESS_HOST:-headlamp.platform.local}"
HEADLAMP_INGRESS_NAME="${HEADLAMP_INGRESS_NAME:-headlamp-ingress}"
HEADLAMP_INGRESS_CLASS="${HEADLAMP_INGRESS_CLASS:-nginx}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-420}"

ENABLE_INGRESS_STACK=1
ENABLE_HEADLAMP=1
SKIP_HEADLAMP_INGRESS=0

SKIP_INGRESS_INSTALL=0
SKIP_METALLB_INSTALL=0
SKIP_POOL_APPLY=0
SKIP_METRICS_SERVER_INSTALL=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/setup_k8s_modern_stack.sh [options]

Installs a modern baseline stack for VM/air-gap Kubernetes:
- ingress-nginx
- MetalLB (L2 pool)
- metrics-server
- Headlamp (ingress optional)

Options:
  --metallb-range <start-end>    MetalLB range (required unless --skip-pool-apply or --skip-ingress-stack).
  --ingress-lb-ip <ip>           Optional fixed LoadBalancer IP for ingress-nginx-controller.
  --metallb-manifest <ref>       Override MetalLB manifest URL/path.
  --ingress-manifest <ref>       Override ingress-nginx manifest URL/path.
  --metrics-server-manifest <ref>
                                 Override metrics-server manifest URL/path.
  --headlamp-manifest <ref>      Override Headlamp manifest path.
  --headlamp-ingress-host <host> Headlamp ingress host. Defaults to headlamp.platform.local.
  --headlamp-ingress-name <name> Headlamp ingress resource name.
  --headlamp-ingress-class <cls> Headlamp ingress class. Defaults to nginx.
  --wait-timeout-sec <n>         Rollout wait timeout seconds. Defaults to 420.

  --skip-ingress-stack           Skip ingress-nginx/MetalLB/metrics-server install.
  --skip-headlamp                Skip Headlamp install.
  --skip-headlamp-ingress        Install Headlamp but skip ingress creation.

  --skip-ingress-install         Forwarded to setup_ingress_metallb.sh.
  --skip-metallb-install         Forwarded to setup_ingress_metallb.sh.
  --skip-pool-apply              Forwarded to setup_ingress_metallb.sh.
  --skip-metrics-server-install  Forwarded to setup_ingress_metallb.sh.

  -h, --help                     Show this help.
USAGE
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --metallb-range)
      [[ $# -ge 2 ]] || die "--metallb-range requires a value"
      METALLB_RANGE="$2"
      shift 2
      ;;
    --ingress-lb-ip)
      [[ $# -ge 2 ]] || die "--ingress-lb-ip requires a value"
      INGRESS_LB_IP="$2"
      shift 2
      ;;
    --metallb-manifest)
      [[ $# -ge 2 ]] || die "--metallb-manifest requires a value"
      METALLB_MANIFEST="$2"
      shift 2
      ;;
    --ingress-manifest)
      [[ $# -ge 2 ]] || die "--ingress-manifest requires a value"
      INGRESS_MANIFEST="$2"
      shift 2
      ;;
    --metrics-server-manifest)
      [[ $# -ge 2 ]] || die "--metrics-server-manifest requires a value"
      METRICS_SERVER_MANIFEST="$2"
      shift 2
      ;;
    --headlamp-manifest)
      [[ $# -ge 2 ]] || die "--headlamp-manifest requires a value"
      HEADLAMP_MANIFEST="$2"
      shift 2
      ;;
    --headlamp-ingress-host)
      [[ $# -ge 2 ]] || die "--headlamp-ingress-host requires a value"
      HEADLAMP_INGRESS_HOST="$2"
      shift 2
      ;;
    --headlamp-ingress-name)
      [[ $# -ge 2 ]] || die "--headlamp-ingress-name requires a value"
      HEADLAMP_INGRESS_NAME="$2"
      shift 2
      ;;
    --headlamp-ingress-class)
      [[ $# -ge 2 ]] || die "--headlamp-ingress-class requires a value"
      HEADLAMP_INGRESS_CLASS="$2"
      shift 2
      ;;
    --wait-timeout-sec)
      [[ $# -ge 2 ]] || die "--wait-timeout-sec requires a value"
      WAIT_TIMEOUT_SEC="$2"
      shift 2
      ;;
    --skip-ingress-stack)
      ENABLE_INGRESS_STACK=0
      shift
      ;;
    --skip-headlamp)
      ENABLE_HEADLAMP=0
      shift
      ;;
    --skip-headlamp-ingress)
      SKIP_HEADLAMP_INGRESS=1
      shift
      ;;
    --skip-ingress-install)
      SKIP_INGRESS_INSTALL=1
      shift
      ;;
    --skip-metallb-install)
      SKIP_METALLB_INSTALL=1
      shift
      ;;
    --skip-pool-apply)
      SKIP_POOL_APPLY=1
      shift
      ;;
    --skip-metrics-server-install)
      SKIP_METRICS_SERVER_INSTALL=1
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

[[ -x "${SCRIPT_DIR}/setup_ingress_metallb.sh" ]] || die "Missing executable script: ${SCRIPT_DIR}/setup_ingress_metallb.sh"
[[ -x "${SCRIPT_DIR}/setup_kubernetes_dashboard.sh" ]] || die "Missing executable script: ${SCRIPT_DIR}/setup_kubernetes_dashboard.sh"

if [[ "${ENABLE_INGRESS_STACK}" == "1" ]]; then
  ingress_args=()

  if [[ -n "${METALLB_RANGE}" ]]; then
    ingress_args+=(--metallb-range "${METALLB_RANGE}")
  fi
  if [[ -n "${INGRESS_LB_IP}" ]]; then
    ingress_args+=(--ingress-lb-ip "${INGRESS_LB_IP}")
  fi
  if [[ -n "${METALLB_MANIFEST}" ]]; then
    ingress_args+=(--metallb-manifest "${METALLB_MANIFEST}")
  fi
  if [[ -n "${INGRESS_MANIFEST}" ]]; then
    ingress_args+=(--ingress-manifest "${INGRESS_MANIFEST}")
  fi
  if [[ -n "${METRICS_SERVER_MANIFEST}" ]]; then
    ingress_args+=(--metrics-server-manifest "${METRICS_SERVER_MANIFEST}")
  fi

  ingress_args+=(--wait-timeout-sec "${WAIT_TIMEOUT_SEC}")

  if [[ "${SKIP_INGRESS_INSTALL}" == "1" ]]; then
    ingress_args+=(--skip-ingress-install)
  fi
  if [[ "${SKIP_METALLB_INSTALL}" == "1" ]]; then
    ingress_args+=(--skip-metallb-install)
  fi
  if [[ "${SKIP_POOL_APPLY}" == "1" ]]; then
    ingress_args+=(--skip-pool-apply)
  fi
  if [[ "${SKIP_METRICS_SERVER_INSTALL}" == "1" ]]; then
    ingress_args+=(--skip-metrics-server-install)
  fi

  if [[ "${SKIP_POOL_APPLY}" != "1" && -z "${METALLB_RANGE}" ]]; then
    die "--metallb-range is required unless --skip-pool-apply or --skip-ingress-stack is used."
  fi

  log "Applying ingress-nginx + MetalLB + metrics-server"
  bash "${SCRIPT_DIR}/setup_ingress_metallb.sh" "${ingress_args[@]}"
else
  log "Skipping ingress-nginx/MetalLB/metrics-server setup"
fi

if [[ "${ENABLE_HEADLAMP}" == "1" ]]; then
  dashboard_args=()

  if [[ -n "${HEADLAMP_MANIFEST}" ]]; then
    dashboard_args+=(--manifest "${HEADLAMP_MANIFEST}")
  fi

  dashboard_args+=(--ingress-host "${HEADLAMP_INGRESS_HOST}")
  dashboard_args+=(--ingress-name "${HEADLAMP_INGRESS_NAME}")
  dashboard_args+=(--ingress-class "${HEADLAMP_INGRESS_CLASS}")

  if [[ "${SKIP_HEADLAMP_INGRESS}" == "1" ]]; then
    dashboard_args+=(--skip-ingress)
  fi

  log "Applying Headlamp"
  bash "${SCRIPT_DIR}/setup_kubernetes_dashboard.sh" "${dashboard_args[@]}"
else
  log "Skipping Headlamp setup"
fi

log "Modern Kubernetes module setup completed."
