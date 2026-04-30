#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-edumgt}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/publish_dockerhub.sh [options]

Options:
  --namespace <name>  Docker Hub namespace. Defaults to edumgt.
  --tag <tag>         Image tag for the platform app images. Defaults to latest.
  --dry-run           Print the delegated build/push command without executing it.
  -h, --help          Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      [[ $# -ge 2 ]] || die "--namespace requires a value"
      IMAGE_NAMESPACE="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || die "--tag requires a value"
      IMAGE_TAG="$2"
      shift 2
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

export IMAGE_NAMESPACE
export IMAGE_TAG

cmd=(bash "${ROOT_DIR}/scripts/build_k8s_images.sh" --namespace "${IMAGE_NAMESPACE}" --tag "${IMAGE_TAG}" --push --skip-runtime-import)

if [[ "${DRY_RUN}" == "1" ]]; then
  printf '+'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  exit 0
fi

"${cmd[@]}"
