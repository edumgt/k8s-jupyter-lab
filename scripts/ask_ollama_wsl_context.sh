#!/usr/bin/env bash
set -euo pipefail

MODEL="${OLLAMA_MODEL:-qwen3.5}"
OLLAMA_CMD="${OLLAMA_CMD:-ollama}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 \"your question about this WSL environment\"" >&2
  exit 1
fi

QUESTION="$*"
ROOT_DIR="$(pwd)"

if ! command -v "${OLLAMA_CMD}" >/dev/null 2>&1; then
  echo "ollama command not found: ${OLLAMA_CMD}" >&2
  exit 1
fi

list_files() {
  find . -maxdepth 3 \
    \( -path "./.git" -o -path "./node_modules" -o -path "./.venv" -o -path "./dist" \) -prune \
    -o -type f -print | sort | head -200
}

git_snapshot() {
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "[git root]"
    git rev-parse --show-toplevel
    echo
    echo "[git status --short]"
    git status --short || true
    echo
    echo "[recent commits]"
    git log --oneline -5 || true
  else
    echo "[git]"
    echo "Not a git repository"
  fi
}

{
  echo "You are analyzing the user's current WSL development environment."
  echo "Answer in Korean unless the user asks otherwise."
  echo "Be concrete and base your answer only on the environment snapshot below."
  echo
  echo "[user question]"
  echo "${QUESTION}"
  echo
  echo "[pwd]"
  echo "${ROOT_DIR}"
  echo
  echo "[whoami]"
  whoami
  echo
  echo "[hostname]"
  hostname
  echo
  echo "[uname -a]"
  uname -a
  echo
  echo "[os release]"
  if [[ -f /etc/os-release ]]; then
    cat /etc/os-release
  fi
  echo
  echo "[disk usage]"
  df -h . || true
  echo
  echo "[top-level files]"
  ls -la
  echo
  echo "[workspace files up to depth 3]"
  list_files
  echo
  git_snapshot
} | "${OLLAMA_CMD}" run "${MODEL}"
