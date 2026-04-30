#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"
BUNDLE_DIR="${BUNDLE_DIR:-/opt/k8s-data-platform/offline-bundle}"
MANIFEST_DIR_REPO="${ROOT_DIR}/offline/manifests"
MANIFEST_DIR_BUNDLE="${BUNDLE_DIR}/k8s/manifests"
EXIT_CODE=0

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(basename "$0")" "$*" >&2
  EXIT_CODE=1
}

check_file() {
  local path="$1"
  local label="$2"
  if [[ -f "${path}" ]]; then
    log "OK: ${label} -> ${path}"
  else
    warn "Missing ${label}: ${path}"
  fi
}

check_image_ref() {
  local ref="$1"
  if sudo ctr -n k8s.io images ls -q | grep -Fqx "${ref}"; then
    log "OK: image present in containerd -> ${ref}"
  else
    warn "Missing image in containerd: ${ref}"
  fi
}

check_k8s() {
  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    warn "Missing /etc/kubernetes/admin.conf"
    return
  fi

  if ! sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes >/dev/null 2>&1; then
    warn "kubectl cannot reach the cluster with /etc/kubernetes/admin.conf"
    return
  fi

  log "Kubernetes API reachable"

  if sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A --no-headers 2>/dev/null | awk '$4 ~ /ImagePullBackOff|ErrImagePull/ {found=1} END{exit found?0:1}'; then
    warn "Found pods with ImagePullBackOff/ErrImagePull"
  else
    log "No current ImagePullBackOff/ErrImagePull pods detected"
  fi

  if sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n ingress-nginx ingress-nginx-controller >/dev/null 2>&1; then
    local ingress_ip
    ingress_ip="$(
      sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true
    )"
    if [[ -n "${ingress_ip}" ]]; then
      log "Ingress LoadBalancer IP assigned -> ${ingress_ip}"
    else
      warn "Ingress LoadBalancer IP is still pending"
    fi
  else
    warn "ingress-nginx-controller service not found"
  fi
}

main() {
  check_file "${MANIFEST_DIR_REPO}/calico.yaml" "repo calico manifest"
  check_file "${MANIFEST_DIR_REPO}/ingress-nginx.yaml" "repo ingress manifest"
  check_file "${MANIFEST_DIR_REPO}/metallb-native.yaml" "repo MetalLB manifest"
  check_file "${MANIFEST_DIR_REPO}/headlamp.yaml" "repo headlamp manifest"

  if [[ -d "${BUNDLE_DIR}" ]]; then
    check_file "${MANIFEST_DIR_BUNDLE}/calico.yaml" "bundle calico manifest"
    check_file "${MANIFEST_DIR_BUNDLE}/ingress-nginx.yaml" "bundle ingress manifest"
    check_file "${MANIFEST_DIR_BUNDLE}/metallb-native.yaml" "bundle MetalLB manifest"
    check_file "${MANIFEST_DIR_BUNDLE}/headlamp.yaml" "bundle headlamp manifest"
  else
    warn "Offline bundle directory not found: ${BUNDLE_DIR}"
  fi

  if command -v ctr >/dev/null 2>&1; then
    check_image_ref "$(platform_support_image platform-calico-cni v3.31.2)"
    check_image_ref "$(platform_support_image platform-calico-node v3.31.2)"
    check_image_ref "$(platform_support_image platform-calico-kube-controllers v3.31.2)"
    check_image_ref "$(platform_support_image platform-metallb-controller v0.15.3)"
    check_image_ref "$(platform_support_image platform-metallb-speaker v0.15.3)"
    check_image_ref "$(platform_support_image platform-ingress-nginx-controller v1.14.1)"
    check_image_ref "$(platform_support_image platform-ingress-nginx-kube-webhook-certgen v1.6.5)"
    check_image_ref "$(platform_support_image platform-headlamp v0.38.0)"
    check_image_ref "$(platform_support_image platform-gitlab-ce 17.10.0-ce.0)"
    check_image_ref "$(platform_support_image platform-nexus3 3.90.1-alpine)"
    check_image_ref "$(platform_app_image backend)"
    check_image_ref "$(platform_app_image frontend)"
    check_image_ref "$(platform_app_image jupyter)"
    check_image_ref "$(platform_app_image airflow)"
  else
    warn "ctr command not found; cannot verify containerd image cache"
  fi

  check_k8s
  exit "${EXIT_CODE}"
}

main "$@"
