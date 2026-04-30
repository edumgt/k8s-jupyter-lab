#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "${ROOT_DIR}/scripts/build_vmware_ova_and_verify.sh" \
  --skip-packer-build \
  --skip-vm-start \
  --skip-verify \
  "$@"
