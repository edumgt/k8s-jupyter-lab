#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/offline-bundle}"
# shellcheck source=scripts/lib/image_registry.sh
source "${ROOT_DIR}/scripts/lib/image_registry.sh"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-data-platform}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE_ARCHIVE_DIR="${IMAGE_ARCHIVE_DIR:-${ROOT_DIR}/.tmp-k8s-images}"
DRY_RUN=0
SKIP_IMAGES=0

usage() {
  cat <<'EOF'
Usage: bash scripts/prepare_offline_bundle.sh [options]

Options:
  --out-dir <path>            Output directory for the offline bundle.
  --registry <host>           Registry host for mirrored images. Defaults to harbor.local.
  --namespace <name>          Registry namespace/project used for mirrored images. Defaults to data-platform.
  --tag <tag>                 Platform app image tag. Defaults to latest.
  --image-archive-dir <path>  Existing image archive directory to reuse with --skip-images.
  --skip-images               Reuse existing image archives and only refresh caches and k8s assets.
  --dry-run                   Print commands without executing them.
  -h, --help                  Show this help.
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

copy_existing_image_archives() {
  local source_dir="$1"
  local target_dir="${OUT_DIR}/images"
  local archives=()
  local archive

  [[ -d "${source_dir}" ]] || die "Image archive directory not found: ${source_dir}"

  mapfile -t archives < <(find "${source_dir}" -maxdepth 1 -type f -name '*.tar' | sort)
  [[ "${#archives[@]}" -gt 0 ]] || die "No image archives found in ${source_dir}"

  run_cmd mkdir -p "${target_dir}"
  for archive in "${archives[@]}"; do
    run_cmd cp "${archive}" "${target_dir}/"
  done
}

download_python_requirements() {
  local app_name="$1"
  local requirements_file="$2"
  local target_dir="${OUT_DIR}/wheels/${app_name}"

  run_cmd mkdir -p "${target_dir}"
  if python3 -m pip --version >/dev/null 2>&1; then
    run_cmd python3 -m pip download --dest "${target_dir}" -r "${requirements_file}"
    return
  fi

  if command -v pip3 >/dev/null 2>&1; then
    run_cmd pip3 download --dest "${target_dir}" -r "${requirements_file}"
    return
  fi

  require_command docker
  run_cmd docker run --rm \
    -v "${requirements_file}:/tmp/requirements.txt:ro" \
    -v "${target_dir}:/wheelhouse" \
    python:3.12-slim \
    /bin/sh -lc "python -m pip download --dest /wheelhouse -r /tmp/requirements.txt"
}

cache_frontend_packages() {
  local cache_dir="${OUT_DIR}/npm-cache"
  local temp_dir

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ %q %q\n' "npm install --prefix <temp-dir> --cache ${cache_dir} --ignore-scripts" "<package.json>"
    return 0
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "${temp_dir}"' RETURN

  mkdir -p "${cache_dir}" "${temp_dir}/home"
  cp "${ROOT_DIR}/apps/frontend/package.json" "${temp_dir}/package.json"
  (
    cd "${temp_dir}"
    HOME="${temp_dir}/home" npm install --cache "${cache_dir}" --ignore-scripts
  )
  cp "${temp_dir}/package-lock.json" "${OUT_DIR}/frontend-package-lock.json"
  rm -rf "${temp_dir}"
  trap - RETURN
}

copy_k8s_assets() {
  local bundle_k8s_dir="${OUT_DIR}/k8s"
  local script_name
  local doc_name

  run_cmd mkdir -p "${bundle_k8s_dir}" "${bundle_k8s_dir}/infra" "${bundle_k8s_dir}/scripts" "${bundle_k8s_dir}/scripts/lib" "${bundle_k8s_dir}/scripts/offline" "${bundle_k8s_dir}/docs" "${bundle_k8s_dir}/manifests"
  run_cmd cp -R "${ROOT_DIR}/infra/k8s" "${bundle_k8s_dir}/infra/"
  if [[ -d "${ROOT_DIR}/offline/manifests" ]]; then
    run_cmd cp "${ROOT_DIR}/offline/manifests/"* "${bundle_k8s_dir}/manifests/"
  fi

  for script_name in apply_k8s.sh reset_k8s.sh status_k8s.sh healthcheck.sh verify.sh verify_nexus_dependencies.sh import_offline_bundle.sh apply_offline_suite.sh audit_registry_scope.sh bootstrap_nexus_repos.sh prime_nexus_caches.sh setup_nexus_offline.sh frontend_dev_setup.sh run_frontend_dev.sh run_frontend_build.sh generate_join_command.sh join_worker_node.sh configure_multinode_cluster.sh setup_ingress_metallb.sh setup_kubernetes_dashboard.sh sync_docker_image_to_vms.sh sync_dashboard_images_to_vms.sh fix_kubelet_network_timeouts.sh check_offline_readiness.sh check_vm_airgap_status.sh install_vm_airgap_postboot_timer.sh; do
    run_cmd cp "${ROOT_DIR}/scripts/${script_name}" "${bundle_k8s_dir}/scripts/${script_name}"
  done
  run_cmd cp "${ROOT_DIR}/scripts/offline/python-dev-seed.txt" "${bundle_k8s_dir}/scripts/offline/python-dev-seed.txt"
  run_cmd cp "${ROOT_DIR}/scripts/offline/npm-dev-seed.txt" "${bundle_k8s_dir}/scripts/offline/npm-dev-seed.txt"
  run_cmd cp "${ROOT_DIR}/scripts/lib/kubernetes_runtime.sh" "${bundle_k8s_dir}/scripts/lib/kubernetes_runtime.sh"

  for doc_name in runbook.md sre-checklist.md stack-roles.md gitlab-repo-layout.md offline-repository.md; do
    run_cmd cp "${ROOT_DIR}/docs/${doc_name}" "${bundle_k8s_dir}/docs/${doc_name}"
  done

  run_cmd cp "${ROOT_DIR}/README.md" "${bundle_k8s_dir}/README.repo.md"

  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ write %q\n' "${bundle_k8s_dir}/README.offline.md"
    return 0
  fi

  cat > "${bundle_k8s_dir}/README.offline.md" <<EOF
# Offline Bundle Quickstart

이 번들은 이미지 tar, Python/NPM 캐시, 오프라인 Kubernetes 적용 자산을 함께 묶어 둔 폐쇄망 배포 세트입니다.

## 포함 내용

- \`../images\`: Docker load / Kubernetes container runtime import 용 OCI tar archive
- \`./infra/k8s\`: dev/prod overlay 와 runner overlay 를 포함한 Kubernetes manifests
- \`./scripts/import_offline_bundle.sh\`: 이미지 import 와 overlay apply helper
- \`./manifests\`: Calico / ingress-nginx / MetalLB / Headlamp 로컬 매니페스트
- \`./scripts/setup_nexus_offline.sh\`: Nexus repo/bootstrap + Python/npm cache warm-up
- \`./scripts/check_offline_readiness.sh\`: 오프라인 준비 상태 점검
- \`./scripts/check_vm_airgap_status.sh\`: VM 기반 air-gap 상태 점검 (node/pod/registry refs)
- \`./scripts/install_vm_airgap_postboot_timer.sh\`: OS 부팅 +10분 자동 점검 timer 설치
- \`./scripts/frontend_dev_setup.sh\`: Nexus/offline npm cache 기반 frontend 의존성 설치
- \`./scripts/verify_nexus_dependencies.sh\`: Nexus(PyPI/npm) 의존성 접근 검증
- \`./scripts/run_frontend_dev.sh\`: Vite 개발 서버 실행
- \`./scripts/offline/*.txt\`: Python/npm 개발용 seed 라이브러리 목록
- \`./docs\`: runbook, SRE checklist, stack roles, GitLab repo layout

## 빠른 적용 예시

\`\`\`bash
bash k8s/scripts/import_offline_bundle.sh --bundle-dir "${OUT_DIR}" --apply --env dev
\`\`\`

OVA 내부 기본 경로에서는 아래 명령을 그대로 사용할 수 있습니다.

\`\`\`bash
bash /opt/k8s-data-platform/scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --apply --env dev
bash /opt/k8s-data-platform/scripts/setup_nexus_offline.sh --namespace data-platform-dev --nexus-url http://127.0.0.1:30091
bash /opt/k8s-data-platform/scripts/frontend_dev_setup.sh
bash /opt/k8s-data-platform/scripts/verify_nexus_dependencies.sh --nexus-url http://127.0.0.1:30091 --username admin --password '<nexus-password>'
bash /opt/k8s-data-platform/scripts/run_frontend_dev.sh
\`\`\`
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
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
    --image-archive-dir)
      [[ $# -ge 2 ]] || die "--image-archive-dir requires a value"
      IMAGE_ARCHIVE_DIR="$2"
      shift 2
      ;;
    --skip-images)
      SKIP_IMAGES=1
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

require_command bash
require_command python3
require_command npm

if [[ "${SKIP_IMAGES}" != "1" ]]; then
  require_command docker
fi

run_cmd mkdir -p "${OUT_DIR}" "${OUT_DIR}/images"

if [[ "${SKIP_IMAGES}" != "1" ]]; then
  run_cmd env TMP_DIR="${OUT_DIR}/images" IMAGE_REGISTRY="${IMAGE_REGISTRY}" IMAGE_NAMESPACE="${IMAGE_NAMESPACE}" IMAGE_TAG="${IMAGE_TAG}" \
    bash "${ROOT_DIR}/scripts/build_k8s_images.sh" --namespace "${IMAGE_NAMESPACE}" --tag "${IMAGE_TAG}" --skip-runtime-import
else
  copy_existing_image_archives "${IMAGE_ARCHIVE_DIR}"
fi

download_python_requirements backend "${ROOT_DIR}/apps/backend/requirements.txt"
download_python_requirements jupyter "${ROOT_DIR}/apps/jupyter/requirements.txt"
download_python_requirements airflow "${ROOT_DIR}/apps/airflow/requirements.txt"
cache_frontend_packages
copy_k8s_assets
