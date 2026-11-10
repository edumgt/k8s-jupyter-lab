#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/quickstart_airgap_mock.sh"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.airgap-mock.yml"
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
  local path="$1"
  if [[ -f "${path}" ]]; then
    record_pass "file exists: ${path#"${REPO_ROOT}/"}"
  else
    record_fail "missing file: ${path}"
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Eq "${pattern}" "${file}"; then
    record_pass "${label}"
  else
    record_fail "${label}"
  fi
}

run_expect_ok() {
  local label="$1"
  shift
  if "$@" >/tmp/airgap-mock-test.out 2>/tmp/airgap-mock-test.err; then
    record_pass "${label}"
  else
    record_fail "${label}"
    cat /tmp/airgap-mock-test.err >&2 || true
  fi
}

run_expect_fail() {
  local label="$1"
  shift
  if "$@" >/tmp/airgap-mock-test.out 2>/tmp/airgap-mock-test.err; then
    record_fail "${label}"
  else
    record_pass "${label}"
  fi
}

assert_file_exists "${SCRIPT}"
assert_file_exists "${COMPOSE_FILE}"
assert_file_exists "${REPO_ROOT}/deploy/airgap-mock/nginx.conf"
assert_file_exists "${REPO_ROOT}/deploy/airgap-mock/html/harbor.html"
assert_file_exists "${REPO_ROOT}/deploy/airgap-mock/html/gitlab.html"
assert_file_exists "${REPO_ROOT}/deploy/airgap-mock/html/nexus.html"
assert_file_exists "${REPO_ROOT}/deploy/airgap-mock/html/airflow.html"

if bash -n "${SCRIPT}"; then
  record_pass "script syntax"
else
  record_fail "script syntax"
fi

run_expect_ok "help exits 0" bash "${SCRIPT}" --help
assert_contains /tmp/airgap-mock-test.out "bash scripts/quickstart_airgap_mock.sh" "help shows the one-liner"

run_expect_ok "dry-run up" bash "${SCRIPT}" --dry-run
assert_contains /tmp/airgap-mock-test.out "docker-compose.airgap-mock.yml" "dry-run names the compose file"
assert_contains /tmp/airgap-mock-test.out "up -d --build" "dry-run builds and starts"
assert_contains /tmp/airgap-mock-test.out "jupyter" "dry-run includes jupyter"

run_expect_ok "dry-run skip jupyter" bash "${SCRIPT}" --dry-run --skip-jupyter --no-build
if grep -Eq '(^| )jupyter( |$)' /tmp/airgap-mock-test.out; then
  record_fail "skip-jupyter still listed jupyter"
else
  record_pass "skip-jupyter omits jupyter"
fi
assert_contains /tmp/airgap-mock-test.out "up -d" "no-build still starts"
if grep -Eq -- '--build' /tmp/airgap-mock-test.out; then
  record_fail "no-build still requested a build"
else
  record_pass "no-build omits --build"
fi

run_expect_ok "dry-run down" bash "${SCRIPT}" down --dry-run --volumes
assert_contains /tmp/airgap-mock-test.out "down --remove-orphans --volumes" "down removes orphans and volumes"

run_expect_fail "unknown option fails" bash "${SCRIPT}" --not-a-flag
run_expect_fail "volumes with up fails" bash "${SCRIPT}" --dry-run --volumes

assert_contains "${COMPOSE_FILE}" "127.0.0.1:30080:80" "frontend uses platform port 30080"
assert_contains "${COMPOSE_FILE}" "127.0.0.1:30081:8000" "backend uses platform port 30081"
assert_contains "${COMPOSE_FILE}" "127.0.0.1:30088:8888" "jupyter uses platform port 30088"
assert_contains "${COMPOSE_FILE}" "127.0.0.1:30083:8083" "harbor mock uses port 30083"
assert_contains "${COMPOSE_FILE}" "127.0.0.1:30089:8089" "gitlab mock uses port 30089"
assert_contains "${COMPOSE_FILE}" "127.0.0.1:30090:8090" "airflow mock uses port 30090"
assert_contains "${COMPOSE_FILE}" "127.0.0.1:30091:8091" "nexus mock uses port 30091"
assert_contains "${REPO_ROOT}/deploy/airgap-mock/nginx.conf" "harbor-mock" "harbor mock health payload"
assert_contains "${REPO_ROOT}/apps/frontend/Dockerfile" "VITE_API_BASE_URL" "frontend build can override API base URL"
assert_contains "${REPO_ROOT}/README.md" "bash scripts/quickstart_airgap_mock.sh" "English README documents the one-liner"
assert_contains "${REPO_ROOT}/readme-kr.md" "bash scripts/quickstart_airgap_mock.sh" "Korean README documents the one-liner"
assert_contains "${REPO_ROOT}/QUICKSTART.md" "bash scripts/quickstart_airgap_mock.sh" "QUICKSTART documents the one-liner"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if docker compose -f "${COMPOSE_FILE}" --project-name k8s-airgap-mock config >/tmp/airgap-mock-compose.out 2>/tmp/airgap-mock-compose.err; then
    record_pass "docker compose config"
  else
    record_fail "docker compose config"
    cat /tmp/airgap-mock-compose.err >&2 || true
  fi
else
  record_pass "docker compose config skipped"
fi

printf 'passed=%s failed=%s\n' "${TESTS_PASSED}" "${TESTS_FAILED}"
[[ "${TESTS_FAILED}" -eq 0 ]]
