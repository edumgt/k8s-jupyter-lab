#!/usr/bin/env bash
set -euo pipefail

IP_ADDR=""
PREFIX=""
GATEWAY=""
DNS_SERVERS=""
IFACE=""
NETPLAN_FILE="/etc/netplan/99-k8s-data-platform-static.yaml"

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/set_static_ip.sh [options]

Options:
  --ip <addr>           Static IPv4 address (e.g. 192.168.253.10)
  --prefix <cidr>       Prefix length (e.g. 24)
  --gateway <addr>      Default gateway
  --dns <csv>           DNS servers comma-separated (e.g. 8.8.8.8,1.1.1.1)
  --iface <name>        Network interface (e.g. ens160)
  --netplan-file <path> Netplan output file path
  -h, --help            Show this help
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)
      [[ $# -ge 2 ]] || die "--ip requires a value"
      IP_ADDR="$2"
      shift 2
      ;;
    --prefix)
      [[ $# -ge 2 ]] || die "--prefix requires a value"
      PREFIX="$2"
      shift 2
      ;;
    --gateway)
      [[ $# -ge 2 ]] || die "--gateway requires a value"
      GATEWAY="$2"
      shift 2
      ;;
    --dns)
      [[ $# -ge 2 ]] || die "--dns requires a value"
      DNS_SERVERS="$2"
      shift 2
      ;;
    --iface)
      [[ $# -ge 2 ]] || die "--iface requires a value"
      IFACE="$2"
      shift 2
      ;;
    --netplan-file)
      [[ $# -ge 2 ]] || die "--netplan-file requires a value"
      NETPLAN_FILE="$2"
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
[[ -n "${IP_ADDR}" ]] || die "--ip is required"
[[ -n "${PREFIX}" ]] || die "--prefix is required"
[[ -n "${GATEWAY}" ]] || die "--gateway is required"
[[ -n "${DNS_SERVERS}" ]] || die "--dns is required"

if [[ -z "${IFACE}" ]]; then
  IFACE="$(ip route | awk '/default/ {print $5; exit}')"
fi
[[ -n "${IFACE}" ]] || die "Could not detect network interface; provide --iface"

dns_yaml="$(printf '%s' "${DNS_SERVERS}" | awk -F',' '{ for (i=1; i<=NF; i++) printf "%s\"%s\"", (i==1?"":", "), $i }')"

install -d -m 0755 "$(dirname "${NETPLAN_FILE}")"
cat > "${NETPLAN_FILE}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: false
      addresses:
        - ${IP_ADDR}/${PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses: [${dns_yaml}]
EOF

chmod 600 "${NETPLAN_FILE}"
netplan generate
netplan apply

printf 'Applied static IP: %s/%s on %s via %s\n' "${IP_ADDR}" "${PREFIX}" "${IFACE}" "${GATEWAY}"

