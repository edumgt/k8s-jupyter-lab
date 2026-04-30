#!/usr/bin/env bash
set -euo pipefail

COMPANY_ROOT="/opt/company"
PLATFORM_ROOT="/opt/k8s-data-platform"
CONFIG_ROOT="/etc/k8s-data-platform"

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/provision_company_layout.sh [options]

Creates the checklist directory structure:
- /opt/company/bin
- /opt/company/config
- /opt/company/images
- /opt/company/packages
- /opt/company/scripts
- /opt/company/docs

Options:
  --company-root <path>   Company root directory (default: /opt/company)
  --platform-root <path>  Platform root directory (default: /opt/k8s-data-platform)
  --config-root <path>    Config root directory (default: /etc/k8s-data-platform)
  -h, --help              Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

link_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "${src}" ]]; then
    ln -sfn "${src}" "${dst}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --company-root)
      [[ $# -ge 2 ]] || die "--company-root requires a value"
      COMPANY_ROOT="$2"
      shift 2
      ;;
    --platform-root)
      [[ $# -ge 2 ]] || die "--platform-root requires a value"
      PLATFORM_ROOT="$2"
      shift 2
      ;;
    --config-root)
      [[ $# -ge 2 ]] || die "--config-root requires a value"
      CONFIG_ROOT="$2"
      shift 2
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

[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."

install -d -m 0755 \
  "${COMPANY_ROOT}/bin" \
  "${COMPANY_ROOT}/config" \
  "${COMPANY_ROOT}/images" \
  "${COMPANY_ROOT}/packages" \
  "${COMPANY_ROOT}/scripts" \
  "${COMPANY_ROOT}/docs"

link_if_exists "${PLATFORM_ROOT}/scripts" "${COMPANY_ROOT}/scripts/k8s-data-platform-scripts"
link_if_exists "${PLATFORM_ROOT}/docs" "${COMPANY_ROOT}/docs/k8s-data-platform-docs"
link_if_exists "${PLATFORM_ROOT}/offline-bundle/images" "${COMPANY_ROOT}/images/offline-images"
link_if_exists "${PLATFORM_ROOT}/offline-bundle/packages" "${COMPANY_ROOT}/packages/offline-packages"
link_if_exists "${CONFIG_ROOT}" "${COMPANY_ROOT}/config/k8s-data-platform-config"

for cmd in platform-apply.sh platform-reset.sh platform-status.sh platform-verify-ova.sh; do
  if [[ -x "/usr/local/bin/${cmd}" ]]; then
    ln -sfn "/usr/local/bin/${cmd}" "${COMPANY_ROOT}/bin/${cmd}"
  fi
done

printf 'Provisioned company layout at %s\n' "${COMPANY_ROOT}"

