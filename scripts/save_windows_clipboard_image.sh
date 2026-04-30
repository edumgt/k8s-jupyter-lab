#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH=""

usage() {
  cat <<'EOF'
Usage: bash scripts/save_windows_clipboard_image.sh [--out FILE]

Saves the current Windows clipboard image into a PNG file that is visible from
WSL. This is useful when Codex in a WSL-backed VS Code session does not support
direct image paste from the clipboard.

Options:
  --out FILE     Destination PNG path. Default:
                 dist/codex-clipboard/clipboard-YYYYmmdd-HHMMSS.png
  -h, --help     Show this help.

Example:
  bash scripts/save_windows_clipboard_image.sh
  bash scripts/save_windows_clipboard_image.sh --out /tmp/capture.png
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || die "--out requires a value"
      OUTPUT_PATH="$2"
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

require_command powershell.exe
require_command wslpath

if [[ -z "${OUTPUT_PATH}" ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  OUTPUT_PATH="${ROOT_DIR}/dist/codex-clipboard/clipboard-${timestamp}.png"
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"
OUTPUT_PATH="$(realpath -m "${OUTPUT_PATH}")"
WINDOWS_OUTPUT_PATH="$(wslpath -w "${OUTPUT_PATH}")"

if ! powershell.exe -NoProfile -STA -Command "
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  \$image = [System.Windows.Forms.Clipboard]::GetImage()
  if (\$null -eq \$image) {
    Write-Error 'No image found in the Windows clipboard.'
    exit 3
  }
  \$outPath = '${WINDOWS_OUTPUT_PATH//\'/''}'
  \$outDir = Split-Path -Parent \$outPath
  if (-not [string]::IsNullOrWhiteSpace(\$outDir)) {
    New-Item -ItemType Directory -Force -Path \$outDir | Out-Null
  }
  \$image.Save(\$outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  \$image.Dispose()
" >/dev/null; then
  die "Failed to save clipboard image. Make sure a screenshot image is currently in the Windows clipboard."
fi

log "Saved clipboard image to ${OUTPUT_PATH}"
log "Next step: use 'Add File to Codex Thread' in VS Code and select this PNG."
