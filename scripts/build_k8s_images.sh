#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/lib/kubernetes_runtime.sh
source "${SCRIPT_DIR}/lib/kubernetes_runtime.sh"
# shellcheck source=scripts/lib/image_registry.sh
source "${SCRIPT_DIR}/lib/image_registry.sh"
TMP_DIR="${TMP_DIR:-${ROOT_DIR}/.tmp-k8s-images}"
DRY_RUN=0
PUSH_IMAGES=0
LOAD_RUNTIME=1
INCLUDE_SUPPORT_IMAGES=1

usage() {
  cat <<'EOF'
Usage: bash scripts/build_k8s_images.sh [options]

Options:
  --registry <host>       Registry host. Defaults to harbor.local.
  --namespace <name>      Registry namespace/project. Defaults to data-platform.
  --tag <tag>             Tag to apply to platform app images. Defaults to latest.
  --push                  Push mirrored support images and built app images with the current docker login.
  --skip-runtime-import   Skip importing the saved archives into the local Kubernetes container runtime cache.
  --skip-support-images   Skip mirroring the upstream base/runtime/CI images into the namespace.
  --dry-run               Print commands without executing them.
  -h, --help              Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
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

import_to_runtime() {
  local archive="$1"

  if [[ "${LOAD_RUNTIME}" != "1" ]]; then
    return 0
  fi

  if [[ "${DRY_RUN}" == "1" ]]; then
    print_runtime_import_cmd "${archive}"
    return 0
  fi

  import_archive_into_runtime "${archive}"
}

sanitize_archive_name() {
  printf '%s' "$1" | tr '/:' '-'
}

save_image_archive() {
  local image="$1"
  local archive="${TMP_DIR}/$(sanitize_archive_name "${image}").tar"

  run_cmd docker save -o "${archive}" "${image}"
  import_to_runtime "${archive}"
}

mirror_support_image() {
  local source_image="$1"
  local target_image="$2"

  run_cmd docker pull "${source_image}"
  run_cmd docker tag "${source_image}" "${target_image}"
  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    run_cmd docker push "${target_image}"
  fi
  save_image_archive "${target_image}"
}

build_platform_image() {
  local name="$1"
  local context="$2"
  local image="$3"
  local frontend_api_url="$4"

  local build_args=(docker build -t "${image}")
  if [[ -n "${frontend_api_url}" ]]; then
    build_args+=(--build-arg "VITE_API_BASE_URL=${frontend_api_url}")
  fi
  build_args+=("${ROOT_DIR}/${context}")

  run_cmd "${build_args[@]}"
  if [[ "${PUSH_IMAGES}" == "1" ]]; then
    run_cmd docker push "${image}"
  fi
  save_image_archive "${image}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      IMAGE_NAMESPACE="$2"
      shift 2
      ;;
    --registry)
      [[ $# -ge 2 ]] || die "--registry requires a value"
      IMAGE_REGISTRY="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --push)
      PUSH_IMAGES=1
      shift
      ;;
    --skip-runtime-import)
      LOAD_RUNTIME=0
      shift
      ;;
    --skip-support-images)
      INCLUDE_SUPPORT_IMAGES=0
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

require_command docker
if [[ "${LOAD_RUNTIME}" == "1" ]]; then
  require_runtime_importer
fi

run_cmd mkdir -p "${TMP_DIR}"

SUPPORT_IMAGES=(
  "python:3.12-slim|$(platform_support_image platform-python 3.12-slim)"
  "python:3.12|$(platform_support_image platform-python 3.12)"
  "node:22.22.0-bookworm-slim|$(platform_support_image platform-node 22.22.0-bookworm-slim)"
  "nginx:1.27-alpine|$(platform_support_image platform-nginx 1.27-alpine)"
  "apache/airflow:2.10.5-python3.12|$(platform_support_image platform-airflow-base 2.10.5-python3.12)"
  "mongo:7.0|$(platform_support_image platform-mongodb 7.0)"
  "redis:7-alpine|$(platform_support_image platform-redis 7-alpine)"
  "gitlab/gitlab-ce:17.10.0-ce.0|$(platform_support_image platform-gitlab-ce 17.10.0-ce.0)"
  "gitlab/gitlab-runner:alpine-v17.10.0|$(platform_support_image platform-gitlab-runner alpine-v17.10.0)"
  "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v17.10.0|$(platform_support_image platform-gitlab-runner-helper x86_64-v17.10.0)"
  "sonatype/nexus3:3.90.1-alpine|$(platform_support_image platform-nexus3 3.90.1-alpine)"
  "gcr.io/kaniko-project/executor:v1.23.2-debug|$(platform_support_image platform-kaniko-executor v1.23.2-debug)"
  "bitnami/kubectl:latest|$(platform_support_image platform-kubectl latest)"
  "bash:5.2|$(platform_support_image platform-bash 5.2)"
  "alpine:3.20|$(platform_support_image platform-alpine 3.20)"
  "busybox:1.36|$(platform_support_image platform-busybox 1.36)"
  "quay.io/calico/cni:v3.31.2|$(platform_support_image platform-calico-cni v3.31.2)"
  "quay.io/calico/node:v3.31.2|$(platform_support_image platform-calico-node v3.31.2)"
  "quay.io/calico/kube-controllers:v3.31.2|$(platform_support_image platform-calico-kube-controllers v3.31.2)"
  "quay.io/metallb/controller:v0.15.3|$(platform_support_image platform-metallb-controller v0.15.3)"
  "quay.io/metallb/speaker:v0.15.3|$(platform_support_image platform-metallb-speaker v0.15.3)"
  "registry.k8s.io/ingress-nginx/controller:v1.14.1|$(platform_support_image platform-ingress-nginx-controller v1.14.1)"
  "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.5|$(platform_support_image platform-ingress-nginx-kube-webhook-certgen v1.6.5)"
  "ghcr.io/headlamp-k8s/headlamp:v0.38.0|$(platform_support_image platform-headlamp v0.38.0)"
)

PLATFORM_IMAGES=(
  "backend|apps/backend|$(platform_app_image backend)|"
  "frontend|apps/frontend|$(platform_app_image frontend)|"
  "airflow|apps/airflow|$(platform_app_image airflow)|"
  "jupyter|apps/jupyter|$(platform_app_image jupyter)|"
)

if [[ "${INCLUDE_SUPPORT_IMAGES}" == "1" ]]; then
  for item in "${SUPPORT_IMAGES[@]}"; do
    IFS='|' read -r source_image target_image <<<"${item}"
    mirror_support_image "${source_image}" "${target_image}"
  done
fi

for item in "${PLATFORM_IMAGES[@]}"; do
  IFS='|' read -r name context image frontend_api_url <<<"${item}"
  build_platform_image "${name}" "${context}" "${image}" "${frontend_api_url}"
done
