#!/usr/bin/env bash
set -euo pipefail

CONFIRM=0
LOG_FILE="/var/log/k8s-data-platform/first-boot.log"

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/first_boot_init.sh --yes-i-understand [options]

One-time initialization helper for cloned golden images:
- regenerate machine-id
- regenerate SSH host keys
- refresh hosts/name service metadata
- write first-boot log

Options:
  --yes-i-understand   Required safety flag.
  --log-file <path>    Log file path (default: /var/log/k8s-data-platform/first-boot.log)
  -h, --help           Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

log() {
  printf '[first-boot] %s\n' "$*" | tee -a "${LOG_FILE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes-i-understand)
      CONFIRM=1
      shift
      ;;
    --log-file)
      [[ $# -ge 2 ]] || die "--log-file requires a value"
      LOG_FILE="$2"
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
[[ "${CONFIRM}" == "1" ]] || die "--yes-i-understand flag is required"

install -d -m 0755 "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}"
chmod 0644 "${LOG_FILE}"

log "starting first boot initialization"

log "regenerating machine-id"
truncate -s 0 /etc/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id

log "regenerating SSH host keys"
rm -f /etc/ssh/ssh_host_*
if command -v dpkg-reconfigure >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive dpkg-reconfigure openssh-server >/dev/null 2>&1 || true
fi
ssh-keygen -A

if command -v cloud-init >/dev/null 2>&1; then
  log "cleaning cloud-init state"
  cloud-init clean --logs || true
fi

log "current hostname: $(hostname)"
log "first boot initialization completed"

