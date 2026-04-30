#!/usr/bin/env bash
set -euo pipefail

METALLB_VERSION="${METALLB_VERSION:-v0.15.3}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.14.1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"
LOCAL_MANIFEST_DIR_DEFAULT="${SCRIPT_DIR%/scripts}/offline/manifests"
REMOTE_BUNDLE_MANIFEST_DIR="/opt/k8s-data-platform/offline-bundle/k8s/manifests"

METALLB_MANIFEST="${METALLB_MANIFEST:-}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-}"

METALLB_NAMESPACE="metallb-system"
INGRESS_NAMESPACE="ingress-nginx"
METALLB_POOL_NAME="platform-pool"
METALLB_L2_NAME="platform-l2"
METALLB_RANGE="${METALLB_RANGE:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-420}"

SKIP_INGRESS_INSTALL=0
SKIP_METALLB_INSTALL=0
SKIP_POOL_APPLY=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/setup_ingress_metallb.sh [options]

Installs NGINX Ingress Controller + MetalLB and configures an L2 address pool.

Options:
  --metallb-range <start-end>    Required unless --skip-pool-apply is used.
                                 Example: 192.168.56.240-192.168.56.250
  --ingress-lb-ip <ip>           Optional fixed LoadBalancer IP for ingress-nginx-controller.
  --metallb-manifest <ref>       MetalLB manifest URL/path. Defaults to official GitHub raw URL.
  --ingress-manifest <ref>       ingress-nginx manifest URL/path. Defaults to official GitHub raw URL.
  --metallb-pool-name <name>     IPAddressPool name. Defaults to platform-pool.
  --metallb-l2-name <name>       L2Advertisement name. Defaults to platform-l2.
  --wait-timeout-sec <n>         Rollout/LoadBalancer wait timeout. Defaults to 420.
  --skip-ingress-install         Skip ingress-nginx manifest apply.
  --skip-metallb-install         Skip MetalLB manifest apply.
  --skip-pool-apply              Skip MetalLB IPAddressPool/L2Advertisement apply.
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

resolve_default_manifest_path() {
  local local_name="$1"
  local remote_url="$2"

  if [[ -f "${LOCAL_MANIFEST_DIR_DEFAULT}/${local_name}" ]]; then
    printf '%s' "${LOCAL_MANIFEST_DIR_DEFAULT}/${local_name}"
    return 0
  fi

  if [[ -f "${REMOTE_BUNDLE_MANIFEST_DIR}/${local_name}" ]]; then
    printf '%s' "${REMOTE_BUNDLE_MANIFEST_DIR}/${local_name}"
    return 0
  fi

  printf '%s' "${remote_url}"
}

resolve_manifest_for_registry() {
  local manifest_path="$1"
  local temp_dir="${2:-}"
  local target_path

  if ! registry_override_enabled || [[ ! -f "${manifest_path}" ]]; then
    printf '%s' "${manifest_path}"
    return 0
  fi

  [[ -n "${temp_dir}" ]] || die "temp dir required for manifest registry rewrite"
  mkdir -p "${temp_dir}"
  target_path="${temp_dir}/$(basename "${manifest_path}")"
  rewrite_registry_prefix_in_file "${manifest_path}" "${target_path}"
  printf '%s' "${target_path}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_kubectl() {
  if [[ -n "${KUBECONFIG:-}" ]]; then
    kubectl "$@"
    return
  fi

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
    return
  fi

  kubectl "$@"
}

wait_rollout() {
  local namespace="$1"
  local resource="$2"
  run_kubectl -n "${namespace}" rollout status "${resource}" --timeout="${WAIT_TIMEOUT_SEC}s"
}

wait_for_ingress_lb_ip() {
  local i
  local lb_ip=""
  local attempts=$(( WAIT_TIMEOUT_SEC / 5 ))

  if [[ "${attempts}" -lt 1 ]]; then
    attempts=1
  fi

  for i in $(seq 1 "${attempts}"); do
    lb_ip="$(run_kubectl -n "${INGRESS_NAMESPACE}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${lb_ip}" ]]; then
      printf '%s' "${lb_ip}"
      return 0
    fi
    sleep 5
  done

  return 1
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
    --metallb-pool-name)
      [[ $# -ge 2 ]] || die "--metallb-pool-name requires a value"
      METALLB_POOL_NAME="$2"
      shift 2
      ;;
    --metallb-l2-name)
      [[ $# -ge 2 ]] || die "--metallb-l2-name requires a value"
      METALLB_L2_NAME="$2"
      shift 2
      ;;
    --wait-timeout-sec)
      [[ $# -ge 2 ]] || die "--wait-timeout-sec requires a value"
      WAIT_TIMEOUT_SEC="$2"
      shift 2
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

require_command kubectl

if [[ -z "${METALLB_MANIFEST}" ]]; then
  METALLB_MANIFEST="$(resolve_default_manifest_path "metallb-native.yaml" "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml")"
fi
if [[ -z "${INGRESS_MANIFEST}" ]]; then
  INGRESS_MANIFEST="$(resolve_default_manifest_path "ingress-nginx.yaml" "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml")"
fi

TMP_MANIFEST_DIR=""
if registry_override_enabled; then
  TMP_MANIFEST_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_MANIFEST_DIR}"' EXIT
  METALLB_MANIFEST="$(resolve_manifest_for_registry "${METALLB_MANIFEST}" "${TMP_MANIFEST_DIR}")"
  INGRESS_MANIFEST="$(resolve_manifest_for_registry "${INGRESS_MANIFEST}" "${TMP_MANIFEST_DIR}")"
fi

if [[ "${SKIP_POOL_APPLY}" -eq 0 && -z "${METALLB_RANGE}" ]]; then
  die "--metallb-range is required unless --skip-pool-apply is used."
fi

if [[ "${SKIP_INGRESS_INSTALL}" -eq 0 ]]; then
  log "Applying ingress-nginx manifest (${INGRESS_MANIFEST})"
  run_kubectl apply -f "${INGRESS_MANIFEST}"
  log "Waiting for ingress-nginx controller rollout"
  wait_rollout "${INGRESS_NAMESPACE}" deployment/ingress-nginx-controller
fi

if [[ "${SKIP_METALLB_INSTALL}" -eq 0 ]]; then
  log "Applying MetalLB manifest (${METALLB_MANIFEST})"
  run_kubectl apply -f "${METALLB_MANIFEST}"
  log "Waiting for MetalLB controller rollout"
  wait_rollout "${METALLB_NAMESPACE}" deployment/controller
  log "Waiting for MetalLB speaker rollout"
  wait_rollout "${METALLB_NAMESPACE}" daemonset/speaker
fi

if [[ "${SKIP_POOL_APPLY}" -eq 0 ]]; then
  log "Applying MetalLB IPAddressPool/L2Advertisement (${METALLB_RANGE})"
  cat <<EOF_POOL | run_kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${METALLB_POOL_NAME}
  namespace: ${METALLB_NAMESPACE}
spec:
  addresses:
    - ${METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${METALLB_L2_NAME}
  namespace: ${METALLB_NAMESPACE}
spec:
  ipAddressPools:
    - ${METALLB_POOL_NAME}
EOF_POOL
fi

if [[ -n "${INGRESS_LB_IP}" ]]; then
  log "Pinning ingress-nginx-controller LoadBalancer IP to ${INGRESS_LB_IP}"
  run_kubectl -n "${INGRESS_NAMESPACE}" patch svc ingress-nginx-controller \
    --type merge \
    -p "{\"spec\":{\"loadBalancerIP\":\"${INGRESS_LB_IP}\"}}"
fi

log "Waiting for ingress-nginx LoadBalancer external IP"
if RESOLVED_LB_IP="$(wait_for_ingress_lb_ip)"; then
  log "ingress-nginx external IP: ${RESOLVED_LB_IP}"
  cat <<EOF_HOSTS

Add these entries to your hosts file:
${RESOLVED_LB_IP} dev.platform.local
${RESOLVED_LB_IP} dev-api.platform.local
${RESOLVED_LB_IP} www.platform.local
${RESOLVED_LB_IP} api.platform.local
${RESOLVED_LB_IP} platform.local
${RESOLVED_LB_IP} jupyter.platform.local
${RESOLVED_LB_IP} gitlab.platform.local
${RESOLVED_LB_IP} airflow.platform.local
${RESOLVED_LB_IP} nexus.platform.local

EOF_HOSTS
else
  log "WARNING: ingress-nginx external IP was not assigned in time."
  log "Check: kubectl -n ${INGRESS_NAMESPACE} get svc ingress-nginx-controller"
fi

log "Ingress/MetalLB setup completed."
