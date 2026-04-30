#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_VERSION_FILE="${ROOT_DIR}/apps/backend/app/version.py"
FRONTEND_PACKAGE_JSON="${ROOT_DIR}/apps/frontend/package.json"

usage() {
  cat <<'EOF'
Usage: bash scripts/bump_be_fe_minor_version.sh

Bump backend/frontend app versions by one minor step:
  0.2.0 -> 0.3.0
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

increment_minor() {
  local current="$1"
  local major minor patch
  IFS='.' read -r major minor patch <<<"${current}"
  [[ "${major}" =~ ^[0-9]+$ ]] || die "Invalid major version: ${current}"
  [[ "${minor}" =~ ^[0-9]+$ ]] || die "Invalid minor version: ${current}"
  [[ "${patch}" =~ ^[0-9]+$ ]] || die "Invalid patch version: ${current}"
  printf '%s.%s.0\n' "${major}" "$((minor + 1))"
}

extract_backend_version() {
  sed -n 's/^BACKEND_APP_VERSION = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' "${BACKEND_VERSION_FILE}"
}

extract_frontend_version() {
  sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)",$/\1/p' "${FRONTEND_PACKAGE_JSON}" | head -n 1
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

[[ -f "${BACKEND_VERSION_FILE}" ]] || die "Backend version file not found: ${BACKEND_VERSION_FILE}"
[[ -f "${FRONTEND_PACKAGE_JSON}" ]] || die "Frontend package.json not found: ${FRONTEND_PACKAGE_JSON}"

backend_current="$(extract_backend_version)"
frontend_current="$(extract_frontend_version)"

[[ -n "${backend_current}" ]] || die "Unable to parse backend version from ${BACKEND_VERSION_FILE}"
[[ -n "${frontend_current}" ]] || die "Unable to parse frontend version from ${FRONTEND_PACKAGE_JSON}"

backend_next="$(increment_minor "${backend_current}")"
frontend_next="$(increment_minor "${frontend_current}")"

sed -i -E "s/^BACKEND_APP_VERSION = \"[0-9]+\\.[0-9]+\\.[0-9]+\"$/BACKEND_APP_VERSION = \"${backend_next}\"/" "${BACKEND_VERSION_FILE}"
sed -i -E "0,/\"version\": \"[0-9]+\\.[0-9]+\\.[0-9]+\"/s//\"version\": \"${frontend_next}\"/" "${FRONTEND_PACKAGE_JSON}"

printf 'backend: %s -> %s\n' "${backend_current}" "${backend_next}"
printf 'frontend: %s -> %s\n' "${frontend_current}" "${frontend_next}"
