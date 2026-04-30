#!/usr/bin/env bash
set -euo pipefail

TARGET_HOSTNAME=""
declare -a HOST_ENTRIES=()
HOSTS_FILE="/etc/hosts"

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/set_hostname_hosts.sh [options]

Options:
  --hostname <name>      Hostname to set (required)
  --entry "<ip> <host>"  Add /etc/hosts fallback entry (repeatable)
  --hosts-file <path>    Hosts file path (default: /etc/hosts)
  -h, --help             Show this help
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      [[ $# -ge 2 ]] || die "--hostname requires a value"
      TARGET_HOSTNAME="$2"
      shift 2
      ;;
    --entry)
      [[ $# -ge 2 ]] || die "--entry requires a value"
      HOST_ENTRIES+=("$2")
      shift 2
      ;;
    --hosts-file)
      [[ $# -ge 2 ]] || die "--hosts-file requires a value"
      HOSTS_FILE="$2"
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
[[ -n "${TARGET_HOSTNAME}" ]] || die "--hostname is required"

hostnamectl set-hostname "${TARGET_HOSTNAME}"

if ! grep -Eq '^127\.0\.1\.1\s+' "${HOSTS_FILE}"; then
  printf '127.0.1.1 %s\n' "${TARGET_HOSTNAME}" >> "${HOSTS_FILE}"
else
  sed -i -E "s/^127\.0\.1\.1\s+.*/127.0.1.1 ${TARGET_HOSTNAME}/" "${HOSTS_FILE}"
fi

for entry in "${HOST_ENTRIES[@]}"; do
  ip="$(printf '%s' "${entry}" | awk '{print $1}')"
  host="$(printf '%s' "${entry}" | awk '{print $2}')"
  [[ -n "${ip}" && -n "${host}" ]] || continue
  if grep -Eq "^[[:space:]]*${ip}[[:space:]]+${host}([[:space:]]+|$)" "${HOSTS_FILE}"; then
    continue
  fi
  printf '%s %s\n' "${ip}" "${host}" >> "${HOSTS_FILE}"
done

printf 'Hostname updated to %s\n' "${TARGET_HOSTNAME}"

