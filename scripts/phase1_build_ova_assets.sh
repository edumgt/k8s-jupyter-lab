#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="all"
DRY_RUN=0

BUNDLE_OUT_DIR="${BUNDLE_OUT_DIR:-${ROOT_DIR}/dist/offline-bundle}"
IMAGE_REGISTRY="${IMAGE_REGISTRY:-harbor.local}"
IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-data-platform}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

PACKER_VARS="${PACKER_VARS:-${ROOT_DIR}/packer/variables.vmware.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"
FORCE_BUILD=0
SKIP_PACKER_BUILD=0
SKIP_VM_START=0
SKIP_VERIFY=0
SKIP_OVA_EXPORT=0

usage() {
  cat <<'EOF'
Usage: bash scripts/phase1_build_ova_assets.sh [mode] [options]

Mode:
  all           Build offline bundle + build/export VMware OVA (default)
  bundle-only   Build offline bundle only
  ova-only      Build/export VMware OVA only

Options:
  --bundle-out-dir PATH    Offline bundle output dir (default: dist/offline-bundle)
  --registry HOST          Bundle image registry (default: harbor.local)
  --namespace NAME         Bundle image namespace (default: data-platform)
  --tag TAG                Bundle app image tag (default: latest)

  --vars-file PATH         VMware packer vars file
  --dist-dir PATH          OVA output dir (Windows style path allowed, default: C:/ffmpeg)
  --force                  Pass --force to build_vmware_ova_and_verify.sh
  --skip-packer-build      Pass --skip-packer-build to build_vmware_ova_and_verify.sh
  --skip-vm-start          Pass --skip-vm-start to build_vmware_ova_and_verify.sh
  --skip-verify            Pass --skip-verify to build_vmware_ova_and_verify.sh
  --skip-ova-export        Pass --skip-ova-export to build_vmware_ova_and_verify.sh
  --dry-run                Print commands only
  -h, --help               Show this help

Examples:
  bash scripts/phase1_build_ova_assets.sh all
  bash scripts/phase1_build_ova_assets.sh bundle-only --bundle-out-dir dist/offline-bundle
  bash scripts/phase1_build_ova_assets.sh ova-only --dist-dir C:/ffmpeg --force
EOF
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

if [[ $# -gt 0 ]]; then
  case "$1" in
    all|bundle-only|ova-only)
      MODE="$1"
      shift
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-out-dir)
      [[ $# -ge 2 ]] || die "--bundle-out-dir requires a value"
      BUNDLE_OUT_DIR="$2"
      shift 2
      ;;
    --registry)
      [[ $# -ge 2 ]] || die "--registry requires a value"
      IMAGE_REGISTRY="$2"
      shift 2
      ;;
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
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || die "--dist-dir requires a value"
      DIST_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE_BUILD=1
      shift
      ;;
    --skip-packer-build)
      SKIP_PACKER_BUILD=1
      shift
      ;;
    --skip-vm-start)
      SKIP_VM_START=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    --skip-ova-export)
      SKIP_OVA_EXPORT=1
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

if [[ "${MODE}" == "all" || "${MODE}" == "bundle-only" ]]; then
  run_cmd bash "${ROOT_DIR}/scripts/prepare_offline_bundle.sh" \
    --out-dir "${BUNDLE_OUT_DIR}" \
    --registry "${IMAGE_REGISTRY}" \
    --namespace "${IMAGE_NAMESPACE}" \
    --tag "${IMAGE_TAG}"
fi

if [[ "${MODE}" == "all" || "${MODE}" == "ova-only" ]]; then
  ova_cmd=(
    bash "${ROOT_DIR}/scripts/build_vmware_ova_and_verify.sh"
    --vars-file "${PACKER_VARS}"
    --dist-dir "${DIST_DIR}"
  )
  if [[ "${FORCE_BUILD}" == "1" ]]; then
    ova_cmd+=(--force)
  fi
  if [[ "${SKIP_PACKER_BUILD}" == "1" ]]; then
    ova_cmd+=(--skip-packer-build)
  fi
  if [[ "${SKIP_VM_START}" == "1" ]]; then
    ova_cmd+=(--skip-vm-start)
  fi
  if [[ "${SKIP_VERIFY}" == "1" ]]; then
    ova_cmd+=(--skip-verify)
  fi
  if [[ "${SKIP_OVA_EXPORT}" == "1" ]]; then
    ova_cmd+=(--skip-ova-export)
  fi
  run_cmd "${ova_cmd[@]}"
fi

