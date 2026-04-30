#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-data-platform}"
GITLAB_URL="${GITLAB_URL:-http://127.0.0.1:30089}"
GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-CHANGE_ME}"
GITLAB_DEMO_PASSWORD="${GITLAB_DEMO_PASSWORD:-123456}"
EXPORT_DIR="${EXPORT_DIR:-${ROOT_DIR}/dist/gitlab-repos}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/gitlab-demo}"
CAPTURES_DIR="${OUT_DIR}/captures"
BOOTSTRAP_REMOTE_PATH="/tmp/gitlab_demo_bootstrap.rb"
DEV1_TOKEN="${DEV1_TOKEN:-$(openssl rand -hex 20)}"
DEV2_TOKEN="${DEV2_TOKEN:-$(openssl rand -hex 20)}"
GITLAB_POD=""
CAPTURE_GITLAB_URL="${CAPTURE_GITLAB_URL:-}"

usage() {
  cat <<'EOF'
Usage: bash scripts/demo_gitlab_repo_flow.sh

Creates demo GitLab users/projects, exports backend/frontend repos, performs
push/pull flows, and writes reusable env/log files under dist/gitlab-demo.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wait_for_gitlab() {
  local attempts=0
  until curl -fsS "${GITLAB_URL}/users/sign_in" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if (( attempts > 120 )); then
      die "Timed out waiting for GitLab at ${GITLAB_URL}"
    fi
    sleep 5
  done
}

detect_gitlab_pod() {
  GITLAB_POD="$(kubectl get pod -n "${NAMESPACE}" -l app=gitlab -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "${GITLAB_POD}" ]] || die "Unable to find gitlab pod in namespace ${NAMESPACE}"
}

detect_capture_gitlab_url() {
  local node_ip

  if [[ -n "${CAPTURE_GITLAB_URL}" ]]; then
    return
  fi

  node_ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
  [[ -n "${node_ip}" ]] || die "Unable to determine Kubernetes node InternalIP for screenshot capture"
  CAPTURE_GITLAB_URL="http://${node_ip}:30089"
}

prepare_dirs() {
  mkdir -p "${OUT_DIR}" "${CAPTURES_DIR}"
}

write_env_file() {
  cat > "${OUT_DIR}/gitlab-demo.env" <<EOF
GITLAB_URL=${CAPTURE_GITLAB_URL}
GITLAB_ROOT_PASSWORD=${GITLAB_ROOT_PASSWORD}
GITLAB_DEMO_PASSWORD=${GITLAB_DEMO_PASSWORD}
GITLAB_DEV1_USERNAME=dev1
GITLAB_DEV1_PASSWORD=${GITLAB_DEMO_PASSWORD}
GITLAB_DEV2_USERNAME=dev2
GITLAB_DEV2_PASSWORD=${GITLAB_DEMO_PASSWORD}
DEV1_TOKEN=${DEV1_TOKEN}
DEV2_TOKEN=${DEV2_TOKEN}
BACKEND_GIT_FLOW_FILE=/workspace/dist/gitlab-demo/captures/backend-git-flow.txt
FRONTEND_GIT_FLOW_FILE=/workspace/dist/gitlab-demo/captures/frontend-git-flow.txt
EOF
}

bootstrap_gitlab() {
  kubectl cp "${ROOT_DIR}/scripts/gitlab_demo_bootstrap.rb" "${NAMESPACE}/${GITLAB_POD}:${BOOTSTRAP_REMOTE_PATH}"
  kubectl exec -n "${NAMESPACE}" "${GITLAB_POD}" -- env \
    GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD}" \
    GITLAB_DEMO_PASSWORD="${GITLAB_DEMO_PASSWORD}" \
    DEV1_HTTP_TOKEN="${DEV1_TOKEN}" \
    DEV2_HTTP_TOKEN="${DEV2_TOKEN}" \
    gitlab-rails runner "${BOOTSTRAP_REMOTE_PATH}"
}

export_repos() {
  bash "${ROOT_DIR}/scripts/export_gitlab_repos.sh" --out-dir "${EXPORT_DIR}" --force
}

reset_git_repo() {
  local repo_dir="$1"
  rm -rf "${repo_dir}/.git"
}

run_logged() {
  local log_file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
    printf '\n'
  } >>"${log_file}" 2>&1
}

configure_repo_identity() {
  local repo_dir="$1"
  local username="$2"
  local email="$3"

  git -C "${repo_dir}" config user.name "${username}"
  git -C "${repo_dir}" config user.email "${email}"
}

commit_all() {
  local repo_dir="$1"
  local message="$2"
  git -C "${repo_dir}" add .
  if git -C "${repo_dir}" diff --cached --quiet; then
    return 0
  fi
  git -C "${repo_dir}" commit -m "${message}" >/dev/null
}

append_demo_note() {
  local file_path="$1"
  local note="$2"
  printf '\n%s\n' "${note}" >>"${file_path}"
}

run_backend_flow() {
  local owner_repo="${EXPORT_DIR}/platform-backend"
  local clone_dir="${OUT_DIR}/dev2-platform-backend-clone"
  local log_file="${CAPTURES_DIR}/backend-git-flow.txt"

  : >"${log_file}"
  reset_git_repo "${owner_repo}"
  rm -rf "${clone_dir}"

  run_logged "${log_file}" git -C "${owner_repo}" init -b main
  configure_repo_identity "${owner_repo}" "dev1" "dev1@dev.com"
  commit_all "${owner_repo}" "Initial backend scaffold from platform-infra"
  git -C "${owner_repo}" remote remove origin >/dev/null 2>&1 || true
  git -C "${owner_repo}" remote add origin "http://oauth2:${DEV1_TOKEN}@127.0.0.1:30089/dev1/platform-backend.git"
  run_logged "${log_file}" git -C "${owner_repo}" push --force-with-lease -u origin main

  run_logged "${log_file}" git clone "${GITLAB_URL}/dev1/platform-backend.git" "${clone_dir}"
  configure_repo_identity "${clone_dir}" "dev2" "dev2@dev.com"

  append_demo_note "${owner_repo}/README.md" "Demo sync note: backend repo updated by dev1 after initial public clone."
  commit_all "${owner_repo}" "Add backend sync note for public pull demo"
  run_logged "${log_file}" git -C "${owner_repo}" push --force-with-lease origin main
  run_logged "${log_file}" git -C "${clone_dir}" pull origin main
}

run_frontend_flow() {
  local owner_repo="${EXPORT_DIR}/platform-frontend"
  local clone_dir="${OUT_DIR}/dev1-platform-frontend-clone"
  local log_file="${CAPTURES_DIR}/frontend-git-flow.txt"

  : >"${log_file}"
  reset_git_repo "${owner_repo}"
  rm -rf "${clone_dir}"

  run_logged "${log_file}" git -C "${owner_repo}" init -b main
  configure_repo_identity "${owner_repo}" "dev2" "dev2@dev.com"
  commit_all "${owner_repo}" "Initial frontend scaffold from platform-infra"
  git -C "${owner_repo}" remote remove origin >/dev/null 2>&1 || true
  git -C "${owner_repo}" remote add origin "http://oauth2:${DEV2_TOKEN}@127.0.0.1:30089/dev2/platform-frontend.git"
  run_logged "${log_file}" git -C "${owner_repo}" push --force-with-lease -u origin main

  run_logged "${log_file}" git clone "${GITLAB_URL}/dev2/platform-frontend.git" "${clone_dir}"
  configure_repo_identity "${clone_dir}" "dev1" "dev1@dev.com"

  append_demo_note "${owner_repo}/README.md" "Demo sync note: frontend repo updated by dev2 after initial public clone."
  commit_all "${owner_repo}" "Add frontend sync note for public pull demo"
  run_logged "${log_file}" git -C "${owner_repo}" push --force-with-lease origin main
  run_logged "${log_file}" git -C "${clone_dir}" pull origin main
}

print_summary() {
  cat <<EOF
GitLab demo flow complete.

- env file: ${OUT_DIR}/gitlab-demo.env
- backend log: ${CAPTURES_DIR}/backend-git-flow.txt
- frontend log: ${CAPTURES_DIR}/frontend-git-flow.txt
- backend project: ${GITLAB_URL}/dev1/platform-backend
- frontend project: ${GITLAB_URL}/dev2/platform-frontend
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
require_command git
require_command curl
require_command openssl

prepare_dirs
wait_for_gitlab
detect_gitlab_pod
detect_capture_gitlab_url
bootstrap_gitlab
export_repos
run_backend_flow
run_frontend_flow
write_env_file
print_summary
