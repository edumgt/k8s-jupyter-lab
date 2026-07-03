#!/usr/bin/env bash
set -euo pipefail

TARGET_NAMESPACES="${TARGET_NAMESPACES:-app,dis,infra,sample,unitest}"
STRICT_HARBOR_PREFIX="${STRICT_HARBOR_PREFIX:-harbor.local/}"
CHECK_METRICS_API=1

usage() {
  cat <<'EOF'
Usage: bash scripts/verify_edumgt_vmware_setup.sh [options]

Verifies EDUMGT setup state on Kubernetes:
  - required namespaces exist
  - metrics APIService is available (optional)
  - pod images in app/dis/infra namespace are Harbor-first

Options:
  --namespaces CSV            Namespace list to verify (default: app,dis,infra,sample,unitest)
  --harbor-prefix PREFIX      Required image prefix (default: harbor.local/)
  --skip-metrics-api-check    Skip metrics APIService check
  -h, --help                  Show help
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespaces)
      [[ $# -ge 2 ]] || die "--namespaces requires a value"
      TARGET_NAMESPACES="$2"
      shift 2
      ;;
    --harbor-prefix)
      [[ $# -ge 2 ]] || die "--harbor-prefix requires a value"
      STRICT_HARBOR_PREFIX="$2"
      shift 2
      ;;
    --skip-metrics-api-check)
      CHECK_METRICS_API=0
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

command -v kubectl >/dev/null 2>&1 || die "kubectl not found"

IFS=',' read -r -a NS_ARRAY <<< "${TARGET_NAMESPACES}"

echo "[verify] namespaces"
for ns in "${NS_ARRAY[@]}"; do
  ns="$(printf '%s' "${ns}" | xargs)"
  [[ -n "${ns}" ]] || continue
  run_kubectl get ns "${ns}" >/dev/null
  echo "OK namespace: ${ns}"
done

if [[ "${CHECK_METRICS_API}" == "1" ]]; then
  echo "[verify] metrics api"
  run_kubectl wait --for=condition=Available --timeout=120s apiservice/v1beta1.metrics.k8s.io >/dev/null
  echo "OK metrics APIService: v1beta1.metrics.k8s.io"
fi

echo "[verify] harbor image prefix in app/dis/infra pods"
bad_refs=0
while IFS= read -r line; do
  ns="$(printf '%s' "${line}" | awk '{print $1}')"
  pod="$(printf '%s' "${line}" | awk '{print $2}')"
  image="$(printf '%s' "${line}" | awk '{print $3}')"
  if [[ "${image}" != ${STRICT_HARBOR_PREFIX}* ]]; then
    echo "BAD image-ref ${ns}/${pod}: ${image}"
    bad_refs=$((bad_refs + 1))
  fi
done < <(
  run_kubectl get pods -n app -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  run_kubectl get pods -n dis -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
  run_kubectl get pods -n infra -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null
)

if [[ "${bad_refs}" -gt 0 ]]; then
  die "Found ${bad_refs} image refs not matching prefix '${STRICT_HARBOR_PREFIX}'."
fi
echo "OK all app/dis/infra pod images use '${STRICT_HARBOR_PREFIX}' prefix"

echo "[verify] done"

