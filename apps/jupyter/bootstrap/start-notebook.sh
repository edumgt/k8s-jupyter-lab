#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${JUPYTER_ROOT_DIR:-/workspace}"

mkdir -p "${ROOT_DIR}"

exec jupyter lab \
  --ip=0.0.0.0 \
  --port=8888 \
  --no-browser \
  --allow-root \
  --ServerApp.token="${JUPYTER_TOKEN:-platform123}" \
  --ServerApp.allow_origin="*" \
  --ServerApp.root_dir="${ROOT_DIR}"
