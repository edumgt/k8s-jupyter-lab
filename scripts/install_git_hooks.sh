#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "This script must be run inside a Git repository." >&2
  exit 1
fi

cd "$repo_root"
git config --local core.hooksPath .githooks

echo "Installed Git hooks from .githooks"
echo "Current hooksPath: $(git config --local --get core.hooksPath)"
