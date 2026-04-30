#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

record_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf 'ok - %s\n' "$1"
}

record_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_file_exists() {
  [[ -f "$1" ]] || {
    printf 'expected file to exist: %s\n' "$1" >&2
    return 1
  }
}

assert_dir_has_files() {
  local path="$1"

  find "${path}" -maxdepth 1 -type f | grep -q . || {
    printf 'expected directory to contain files: %s\n' "${path}" >&2
    return 1
  }
}

make_fixture_repo() {
  local target="$1"
  local script_name
  local doc_name

  mkdir -p "${target}/scripts" "${target}/scripts/lib" "${target}/scripts/offline" "${target}/apps" "${target}/infra" "${target}/docs" "${target}/offline/manifests"
  for script_name in prepare_offline_bundle.sh import_offline_bundle.sh apply_k8s.sh reset_k8s.sh status_k8s.sh healthcheck.sh verify.sh verify_nexus_dependencies.sh apply_offline_suite.sh audit_registry_scope.sh bootstrap_nexus_repos.sh prime_nexus_caches.sh setup_nexus_offline.sh frontend_dev_setup.sh run_frontend_dev.sh run_frontend_build.sh generate_join_command.sh join_worker_node.sh configure_multinode_cluster.sh setup_ingress_metallb.sh setup_kubernetes_dashboard.sh sync_docker_image_to_vms.sh sync_dashboard_images_to_vms.sh fix_kubelet_network_timeouts.sh check_offline_readiness.sh check_vm_airgap_status.sh install_vm_airgap_postboot_timer.sh; do
    cp "${REPO_ROOT}/scripts/${script_name}" "${target}/scripts/${script_name}"
  done
  cp "${REPO_ROOT}/scripts/lib/kubernetes_runtime.sh" "${target}/scripts/lib/kubernetes_runtime.sh"
  cp "${REPO_ROOT}/scripts/lib/image_registry.sh" "${target}/scripts/lib/image_registry.sh"
  cp "${REPO_ROOT}/scripts/offline/python-dev-seed.txt" "${target}/scripts/offline/python-dev-seed.txt"
  cp "${REPO_ROOT}/scripts/offline/npm-dev-seed.txt" "${target}/scripts/offline/npm-dev-seed.txt"
  chmod +x "${target}/scripts/"*.sh

  mkdir -p "${target}/apps/backend" "${target}/apps/jupyter" "${target}/apps/airflow" "${target}/apps/frontend"
  printf 'fastapi\n' > "${target}/apps/backend/requirements.txt"
  printf 'jupyterlab\n' > "${target}/apps/jupyter/requirements.txt"
  printf 'apache-airflow\n' > "${target}/apps/airflow/requirements.txt"
  printf '{\"name\":\"frontend\",\"private\":true}\n' > "${target}/apps/frontend/package.json"

  cp -R "${REPO_ROOT}/infra/k8s" "${target}/infra/"
  cp "${REPO_ROOT}/offline/manifests/"* "${target}/offline/manifests/"
  for doc_name in runbook.md sre-checklist.md stack-roles.md gitlab-repo-layout.md offline-repository.md; do
    cp "${REPO_ROOT}/docs/${doc_name}" "${target}/docs/${doc_name}"
  done
  cp "${REPO_ROOT}/README.md" "${target}/README.md"
}

test_prepare_offline_bundle_reuses_archives_and_copies_k8s_assets() (
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  make_fixture_repo "${tmp_dir}"
  mkdir -p "${tmp_dir}/.tmp-k8s-images" "${tmp_dir}/bin"
  printf 'fake-image-archive\n' > "${tmp_dir}/.tmp-k8s-images/platform-backend.tar"

  cat > "${tmp_dir}/bin/python3" <<'EOF'
#!/usr/bin/env bash
dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      dest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "${dest}"
printf 'wheel-placeholder\n' > "${dest}/offline-placeholder.whl"
EOF

  cat > "${tmp_dir}/bin/npm" <<'EOF'
#!/usr/bin/env bash
cache_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache)
      cache_dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "${cache_dir}"
printf '{\"lockfileVersion\":3}\n' > package-lock.json
EOF

  cat > "${tmp_dir}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "${tmp_dir}/bin/python3" "${tmp_dir}/bin/npm" "${tmp_dir}/bin/docker"
  PATH="${tmp_dir}/bin:${PATH}" bash "${tmp_dir}/scripts/prepare_offline_bundle.sh" \
    --out-dir "${tmp_dir}/dist/offline-bundle" \
    --skip-images

  assert_file_exists "${tmp_dir}/dist/offline-bundle/images/platform-backend.tar"
  assert_dir_has_files "${tmp_dir}/dist/offline-bundle/wheels/backend"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/frontend-package-lock.json"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/infra/k8s/base/kustomization.yaml"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/scripts/import_offline_bundle.sh"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/scripts/lib/kubernetes_runtime.sh"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/scripts/setup_nexus_offline.sh"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/scripts/verify_nexus_dependencies.sh"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/docs/runbook.md"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/docs/offline-repository.md"
  assert_file_exists "${tmp_dir}/dist/offline-bundle/k8s/README.offline.md"
)

run_test() {
  local name="$1"

  if "${name}"; then
    record_pass "${name}"
  else
    record_fail "${name}"
  fi
}

run_test test_prepare_offline_bundle_reuses_archives_and_copies_k8s_assets

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
  printf '%s tests failed\n' "${TESTS_FAILED}" >&2
  exit 1
fi

printf '%s tests passed\n' "${TESTS_PASSED}"
