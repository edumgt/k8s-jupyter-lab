#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/kubernetes_runtime.sh
source "${SCRIPT_DIR}/lib/kubernetes_runtime.sh"

BUNDLE_DIR="${BUNDLE_DIR:-/opt/k8s-data-platform/offline-bundle}"
DRY_RUN=0
IMPORT_DOCKER=1
IMPORT_RUNTIME=1
APPLY_MANIFESTS=0

usage() {
  cat <<'USAGE'
Usage: bash scripts/import_offline_bundle.sh [options]

Options:
  --bundle-dir <path>  Offline bundle root. Default: /opt/k8s-data-platform/offline-bundle
  --apply              Apply bundled manifest files after import
  --docker-only        Import to Docker only
  --runtime-only       Import to containerd runtime only
  --dry-run            Print commands only
  -h, --help           Show this help
USAGE
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --apply)
      APPLY_MANIFESTS=1
      shift
      ;;
    --docker-only)
      IMPORT_DOCKER=1
      IMPORT_RUNTIME=0
      shift
      ;;
    --runtime-only)
      IMPORT_DOCKER=0
      IMPORT_RUNTIME=1
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

[[ "${IMPORT_DOCKER}" == "1" || "${IMPORT_RUNTIME}" == "1" ]] || die "Nothing to import"

IMAGES_DIR="${BUNDLE_DIR}/images"
MANIFEST_DIR="${BUNDLE_DIR}/manifests"

[[ -d "${IMAGES_DIR}" ]] || die "Images directory not found: ${IMAGES_DIR}"

if [[ "${IMPORT_DOCKER}" == "1" ]]; then
  command -v docker >/dev/null 2>&1 || die "docker command not found"
fi
if [[ "${IMPORT_RUNTIME}" == "1" ]]; then
  require_runtime_importer
fi
if [[ "${APPLY_MANIFESTS}" == "1" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "kubectl command not found"
  [[ -d "${MANIFEST_DIR}" ]] || die "Manifest directory not found: ${MANIFEST_DIR}"
fi

mapfile -t archives < <(find "${IMAGES_DIR}" -maxdepth 1 -type f -name '*.tar' | sort)
[[ "${#archives[@]}" -gt 0 ]] || die "No image archives found in ${IMAGES_DIR}"

for archive in "${archives[@]}"; do
  if [[ "${IMPORT_DOCKER}" == "1" ]]; then
    run_cmd docker load -i "${archive}"
  fi
  if [[ "${IMPORT_RUNTIME}" == "1" ]]; then
    if [[ "${DRY_RUN}" == "1" ]]; then
      print_runtime_import_cmd "${archive}"
    else
      import_archive_into_runtime "${archive}"
    fi
  fi
done

if [[ "${APPLY_MANIFESTS}" == "1" ]]; then
  mapfile -t yaml_files < <(find "${MANIFEST_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)
  [[ "${#yaml_files[@]}" -gt 0 ]] || die "No manifest files found in ${MANIFEST_DIR}"
  for y in "${yaml_files[@]}"; do
    run_cmd kubectl apply -f "${y}"
  done
fi

if [[ "${DRY_RUN}" != "1" ]]; then
  run_kubectl get nodes -o wide || true
fi
