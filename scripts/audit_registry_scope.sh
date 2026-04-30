#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXIT_CODE=0

RUNTIME_PATHS=(
  "${ROOT_DIR}/infra/k8s"
  "${ROOT_DIR}/offline/manifests"
  "${ROOT_DIR}/apps/backend/app/config.py"
  "${ROOT_DIR}/apps/backend/app/services/jupyter_snapshots.py"
)

runtime_docker_refs="$(
  rg -o 'docker\.io/[^\" ]+' "${RUNTIME_PATHS[@]}" -g '!**/node_modules/**' | sort -u || true
)"

runtime_harbor_refs="$(
  rg -o 'harbor\.local/[^\" ]+' "${RUNTIME_PATHS[@]}" -g '!**/node_modules/**' | sort -u || true
)"

printf 'Runtime Harbor refs:\n%s\n\n' "${runtime_harbor_refs:-<none>}"
printf 'Runtime docker.io refs:\n%s\n\n' "${runtime_docker_refs:-<none>}"

if [[ -n "${runtime_docker_refs}" ]]; then
  printf 'Result: FAIL (runtime path contains docker.io refs)\n'
  EXIT_CODE=1
elif [[ -n "${runtime_harbor_refs}" ]]; then
  printf 'Result: PASS (runtime path is Harbor-first)\n'
else
  printf 'Result: FAIL (no Harbor runtime refs found)\n'
  EXIT_CODE=1
fi

exit "${EXIT_CODE}"
