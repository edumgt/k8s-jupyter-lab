#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/tmp/k8s-data-platform-src}"
PLAYBOOK_PATH=""
SKIP_APT=0

usage() {
  cat <<'EOF'
Usage: bash scripts/bootstrap_local_vm.sh [options]

Options:
  --repo-root <path>  Repository payload root inside the VM.
  --playbook <path>   Override ansible playbook path. Defaults to <repo-root>/ansible/playbook.yml.
  --skip-apt          Skip apt install for ansible and run playbook directly.
  -h, --help          Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || die "--repo-root requires a value"
      REPO_ROOT="$2"
      shift 2
      ;;
    --playbook)
      [[ $# -ge 2 ]] || die "--playbook requires a value"
      PLAYBOOK_PATH="$2"
      shift 2
      ;;
    --skip-apt)
      SKIP_APT=1
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

[[ -d "${REPO_ROOT}/ansible" ]] || die "ansible directory not found under ${REPO_ROOT}"
if [[ -z "${PLAYBOOK_PATH}" ]]; then
  PLAYBOOK_PATH="${REPO_ROOT}/ansible/playbook.yml"
fi
[[ -f "${PLAYBOOK_PATH}" ]] || die "playbook not found: ${PLAYBOOK_PATH}"

if [[ "${SKIP_APT}" == "0" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ansible
fi

ansible-playbook -i 'localhost,' -c local "${PLAYBOOK_PATH}"
