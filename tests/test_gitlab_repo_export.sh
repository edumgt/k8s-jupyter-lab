#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

assert_file_exists() {
  local path="$1"
  [[ -f "${path}" ]] || {
    printf 'Expected file not found: %s\n' "${path}" >&2
    exit 1
  }
}

assert_contains() {
  local path="$1"
  local expected="$2"

  grep -Fq "${expected}" "${path}" || {
    printf 'Expected content not found in %s: %s\n' "${path}" "${expected}" >&2
    exit 1
  }
}

bash "${ROOT_DIR}/scripts/export_gitlab_repos.sh" --out-dir "${TMP_DIR}/gitlab-repos"

assert_file_exists "${TMP_DIR}/gitlab-repos/README.md"

for repo in platform-backend platform-frontend platform-airflow platform-jupyter; do
  assert_file_exists "${TMP_DIR}/gitlab-repos/${repo}/.gitlab-ci.yml"
  assert_file_exists "${TMP_DIR}/gitlab-repos/${repo}/README.md"
  assert_file_exists "${TMP_DIR}/gitlab-repos/${repo}/.gitignore"
done

assert_contains "${TMP_DIR}/gitlab-repos/platform-backend/.gitlab-ci.yml" "kubectl set image deployment/backend"
assert_contains "${TMP_DIR}/gitlab-repos/platform-frontend/.gitlab-ci.yml" "kubectl set image deployment/frontend"
assert_contains "${TMP_DIR}/gitlab-repos/platform-airflow/.gitlab-ci.yml" "kubectl set image deployment/airflow"
assert_contains "${TMP_DIR}/gitlab-repos/platform-jupyter/.gitlab-ci.yml" "kubectl set image deployment/jupyter"

assert_file_exists "${TMP_DIR}/gitlab-repos/platform-backend/app/main.py"
assert_file_exists "${TMP_DIR}/gitlab-repos/platform-frontend/src/App.vue"
assert_file_exists "${TMP_DIR}/gitlab-repos/platform-airflow/dags/platform_health_dag.py"
assert_file_exists "${TMP_DIR}/gitlab-repos/platform-jupyter/bootstrap/start-notebook.sh"
