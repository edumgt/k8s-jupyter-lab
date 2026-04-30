#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCAL_MANIFEST_DIR_DEFAULT="${ROOT_DIR}/offline/manifests"
REMOTE_BUNDLE_MANIFEST_DIR="/opt/k8s-data-platform/offline-bundle/k8s/manifests"

HEADLAMP_NAMESPACE="headlamp"
HEADLAMP_MANIFEST="${HEADLAMP_MANIFEST:-}"
INGRESS_NAME="${INGRESS_NAME:-headlamp-ingress}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-nginx}"
INGRESS_HOST="${INGRESS_HOST:-dashboard.platform.local}"

SKIP_INGRESS=0
SKIP_ADMIN_BINDING=0
PRINT_TOKEN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/setup_kubernetes_dashboard.sh [options]

Installs Headlamp from the air-gap manifest and optionally creates ingress.

This script keeps its original filename for backward compatibility, but it now
manages Headlamp instead of Kubernetes Dashboard.

Options:
  --manifest PATH             Headlamp manifest path.
                              Defaults:
                                1) /opt/k8s-data-platform/offline-bundle/k8s/manifests/headlamp.yaml
                                2) ./offline/manifests/headlamp.yaml
  --ingress-host HOST         Headlamp ingress host (default: dashboard.platform.local)
  --ingress-name NAME         Ingress resource name (default: headlamp-ingress)
  --ingress-class NAME        IngressClass name (default: nginx)
  --skip-ingress              Skip ingress creation.
  --skip-admin-binding        Deprecated no-op kept for compatibility.
  --print-token               Deprecated no-op kept for compatibility.
  -h, --help                  Show this help.
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
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

resolve_manifest_path() {
  if [[ -n "${HEADLAMP_MANIFEST}" ]]; then
    printf '%s' "${HEADLAMP_MANIFEST}"
    return 0
  fi

  if [[ -f "${REMOTE_BUNDLE_MANIFEST_DIR}/headlamp.yaml" ]]; then
    printf '%s' "${REMOTE_BUNDLE_MANIFEST_DIR}/headlamp.yaml"
    return 0
  fi

  printf '%s' "${LOCAL_MANIFEST_DIR_DEFAULT}/headlamp.yaml"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      [[ $# -ge 2 ]] || die "--manifest requires a value"
      HEADLAMP_MANIFEST="$2"
      shift 2
      ;;
    --ingress-host)
      [[ $# -ge 2 ]] || die "--ingress-host requires a value"
      INGRESS_HOST="$2"
      shift 2
      ;;
    --ingress-name)
      [[ $# -ge 2 ]] || die "--ingress-name requires a value"
      INGRESS_NAME="$2"
      shift 2
      ;;
    --ingress-class)
      [[ $# -ge 2 ]] || die "--ingress-class requires a value"
      INGRESS_CLASS_NAME="$2"
      shift 2
      ;;
    --skip-ingress)
      SKIP_INGRESS=1
      shift
      ;;
    --skip-admin-binding)
      SKIP_ADMIN_BINDING=1
      shift
      ;;
    --print-token)
      PRINT_TOKEN=1
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

MANIFEST_PATH="$(resolve_manifest_path)"
[[ -f "${MANIFEST_PATH}" ]] || die "Headlamp manifest not found: ${MANIFEST_PATH}"

log "Applying Headlamp manifest: ${MANIFEST_PATH}"
run_kubectl apply -f "${MANIFEST_PATH}"

log "Waiting for Headlamp rollout"
run_kubectl -n "${HEADLAMP_NAMESPACE}" rollout status deploy/headlamp --timeout=300s

if [[ "${SKIP_INGRESS}" == "0" ]]; then
  log "Creating/updating Headlamp ingress (${INGRESS_HOST})"
  cat <<EOF_ING | run_kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${HEADLAMP_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/service-upstream: "true"
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${INGRESS_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: headlamp
                port:
                  number: 80
EOF_ING
fi

if [[ "${SKIP_ADMIN_BINDING}" == "1" ]]; then
  log "--skip-admin-binding is deprecated and ignored for Headlamp"
fi

ingress_ip="$(
  run_kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
)"

printf '\n'
log "Headlamp URL: http://${INGRESS_HOST}/"
if [[ -n "${ingress_ip}" ]]; then
  log "hosts entry: ${ingress_ip} ${INGRESS_HOST}"
fi
log "Headlamp runs with the in-cluster admin ServiceAccount defined in headlamp.yaml"

if [[ "${PRINT_TOKEN}" == "1" ]]; then
  log "--print-token is deprecated and ignored for Headlamp"
fi
