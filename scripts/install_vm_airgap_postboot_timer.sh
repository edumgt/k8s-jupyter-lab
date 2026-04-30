#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT_PATH="${CHECK_SCRIPT_PATH:-${SCRIPT_DIR}/check_vm_airgap_status.sh}"
EXPECTED_NODES="${EXPECTED_NODES:-k8s-data-platform,k8s-worker-1,k8s-worker-2,k8s-worker-3}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-1200}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"
LOG_DIR="${LOG_DIR:-/var/log/k8s-data-platform}"

SERVICE_NAME="k8s-vm-airgap-postboot-check.service"
TIMER_NAME="k8s-vm-airgap-postboot-check.timer"
UNIT_DIR="/etc/systemd/system"
DISABLE_ONLY=0
RUN_NOW=0

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/install_vm_airgap_postboot_timer.sh [options]

Installs a systemd timer that runs VM air-gap status check once at boot +10 minutes.
The checker waits for expected node readiness before validating air-gap conditions.

Options:
  --script-path PATH        Checker script path.
                            Default: scripts/check_vm_airgap_status.sh
  --expected-nodes CSV      Expected node names.
                            Default: k8s-data-platform,k8s-worker-1,k8s-worker-2,k8s-worker-3
  --wait-timeout-sec N      Max wait for cluster/node readiness (default: 1200)
  --poll-interval-sec N     Poll interval while waiting (default: 10)
  --log-dir PATH            Log directory passed to checker (default: /var/log/k8s-data-platform)
  --run-now                 Start the service immediately once after install
  --disable                 Disable timer and remove installed unit files
  -h, --help                Show this help
EOF
}

log() {
  printf '[install_vm_airgap_postboot_timer.sh] %s\n' "$*"
}

die() {
  printf '[install_vm_airgap_postboot_timer.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo)."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --script-path)
      [[ $# -ge 2 ]] || die "--script-path requires a value"
      CHECK_SCRIPT_PATH="$2"
      shift 2
      ;;
    --expected-nodes)
      [[ $# -ge 2 ]] || die "--expected-nodes requires a value"
      EXPECTED_NODES="$2"
      shift 2
      ;;
    --wait-timeout-sec)
      [[ $# -ge 2 ]] || die "--wait-timeout-sec requires a value"
      WAIT_TIMEOUT_SEC="$2"
      shift 2
      ;;
    --poll-interval-sec)
      [[ $# -ge 2 ]] || die "--poll-interval-sec requires a value"
      POLL_INTERVAL_SEC="$2"
      shift 2
      ;;
    --log-dir)
      [[ $# -ge 2 ]] || die "--log-dir requires a value"
      LOG_DIR="$2"
      shift 2
      ;;
    --run-now)
      RUN_NOW=1
      shift
      ;;
    --disable)
      DISABLE_ONLY=1
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

require_root
require_command systemctl

if [[ "${DISABLE_ONLY}" -eq 1 ]]; then
  log "Disabling ${TIMER_NAME} and removing unit files."
  systemctl disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  rm -f "${UNIT_DIR}/${SERVICE_NAME}" "${UNIT_DIR}/${TIMER_NAME}"
  systemctl daemon-reload
  log "Disabled and removed."
  exit 0
fi

CHECK_SCRIPT_PATH="$(readlink -f "${CHECK_SCRIPT_PATH}")"
[[ -f "${CHECK_SCRIPT_PATH}" ]] || die "Checker script not found: ${CHECK_SCRIPT_PATH}"
chmod +x "${CHECK_SCRIPT_PATH}"

cat > "${UNIT_DIR}/${SERVICE_NAME}" <<EOF
[Unit]
Description=VM air-gap status check (post-boot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Environment=EXPECTED_NODES=${EXPECTED_NODES}
Environment=WAIT_TIMEOUT_SEC=${WAIT_TIMEOUT_SEC}
Environment=POLL_INTERVAL_SEC=${POLL_INTERVAL_SEC}
Environment=LOG_DIR=${LOG_DIR}
ExecStart=/bin/bash ${CHECK_SCRIPT_PATH}
EOF

cat > "${UNIT_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Run VM air-gap status check at boot +10 minutes

[Timer]
OnBootSec=10min
AccuracySec=30s
Persistent=true
Unit=${SERVICE_NAME}

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${TIMER_NAME}"

if [[ "${RUN_NOW}" -eq 1 ]]; then
  systemctl start "${SERVICE_NAME}"
fi

log "Installed timer: ${TIMER_NAME}"
systemctl status "${TIMER_NAME}" --no-pager || true
systemctl list-timers "${TIMER_NAME}" --no-pager || true
