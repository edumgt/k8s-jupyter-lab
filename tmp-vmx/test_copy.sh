#!/usr/bin/env bash
set -euo pipefail
p="$(wslpath -w /home/Kubernetes-Jupyter-Sandbox/tmp-vmx/k8s-worker-3.vmx)"
echo "SRC_WIN=$p"
powershell.exe -NoProfile -Command "New-Item -ItemType Directory -Force -Path 'C:\ffmpeg' | Out-Null; Copy-Item -LiteralPath '$p' -Destination 'C:\ffmpeg\k8s-worker-3.vmx' -Force; Get-Item 'C:\ffmpeg\k8s-worker-3.vmx' | Select-Object FullName,Length"
