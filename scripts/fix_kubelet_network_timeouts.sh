#!/usr/bin/env bash
set -euo pipefail

DNS_SERVERS="${DNS_SERVERS:-}"
FALLBACK_DNS="${FALLBACK_DNS:-1.1.1.1,8.8.8.8}"
KUBELET_PORT="${KUBELET_PORT:-10250}"
KUBE_PROXY_HEALTHZ_PORT="${KUBE_PROXY_HEALTHZ_PORT:-10256}"
SKIP_CONTAINERD_RESTART=0

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/fix_kubelet_network_timeouts.sh [options]

Fixes common kubelet/network timeout issues:
  - kubelet API (:10250) timeout caused by firewall policy
  - image pull DNS timeout caused by unstable node resolver setup
  - pod-to-pod/network forwarding drops caused by UFW forward policy

Options:
  --dns-servers CSV            Preferred DNS servers (e.g. <YOUR_GATEWAY_IP>,1.1.1.1,8.8.8.8).
  --fallback-dns CSV           Fallback DNS list (default: 1.1.1.1,8.8.8.8).
  --kubelet-port PORT          kubelet secure API port (default: 10250).
  --kube-proxy-port PORT       kube-proxy health port (default: 10256).
  --skip-containerd-restart    Skip containerd restart.
  -h, --help                   Show this help.
EOF
}

die() {
  printf '[fix_kubelet_network_timeouts] ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[fix_kubelet_network_timeouts] %s\n' "$*"
}

ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root or with sudo."
}

csv_unique() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed 's/[[:space:]]//g' \
    | awk 'NF && !seen[$0]++' \
    | paste -sd, -
}

csv_to_space() {
  printf '%s' "$1" | tr ',' ' '
}

discover_nameservers_from_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '/^nameserver[[:space:]]+/ { print $2 }' "${file}" \
    | grep -Ev '^127\.|^::1$' \
    | awk '!seen[$0]++' \
    | paste -sd, -
}

has_non_loopback_nameserver() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  awk '
    /^nameserver[[:space:]]+/ {
      if ($2 !~ /^127\./ && $2 != "::1") {
        found=1
      }
    }
    END { exit(found ? 0 : 1) }
  ' "${file}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dns-servers)
      [[ $# -ge 2 ]] || die "--dns-servers requires a value"
      DNS_SERVERS="$2"
      shift 2
      ;;
    --fallback-dns)
      [[ $# -ge 2 ]] || die "--fallback-dns requires a value"
      FALLBACK_DNS="$2"
      shift 2
      ;;
    --kubelet-port)
      [[ $# -ge 2 ]] || die "--kubelet-port requires a value"
      KUBELET_PORT="$2"
      shift 2
      ;;
    --kube-proxy-port)
      [[ $# -ge 2 ]] || die "--kube-proxy-port requires a value"
      KUBE_PROXY_HEALTHZ_PORT="$2"
      shift 2
      ;;
    --skip-containerd-restart)
      SKIP_CONTAINERD_RESTART=1
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

ensure_root

FALLBACK_DNS="$(csv_unique "${FALLBACK_DNS}")"
if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="$(discover_nameservers_from_file "/run/systemd/resolve/resolv.conf")"
fi
if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="$(discover_nameservers_from_file "/etc/resolv.conf")"
fi
if [[ -z "${DNS_SERVERS}" ]]; then
  DNS_SERVERS="${FALLBACK_DNS}"
fi
DNS_SERVERS="$(csv_unique "${DNS_SERVERS},${FALLBACK_DNS}")"
[[ -n "${DNS_SERVERS}" ]] || die "Unable to resolve DNS server list."

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-k8s-data-platform.conf <<EOF
[Resolve]
DNS=$(csv_to_space "${DNS_SERVERS}")
FallbackDNS=$(csv_to_space "${FALLBACK_DNS}")
EOF

if systemctl list-unit-files | grep -q '^systemd-resolved.service'; then
  systemctl restart systemd-resolved
fi

KUBELET_RESOLV_CONF="/run/systemd/resolve/resolv.conf"
if [[ ! -f "${KUBELET_RESOLV_CONF}" ]]; then
  KUBELET_RESOLV_CONF="/etc/resolv.conf"
fi
if ! has_non_loopback_nameserver "${KUBELET_RESOLV_CONF}"; then
  KUBELET_RESOLV_CONF="/etc/resolv.conf"
fi

existing_extra_args=""
if [[ -f /etc/default/kubelet ]]; then
  existing_extra_args="$(
    awk -F '=' '/^KUBELET_EXTRA_ARGS=/{print $2}' /etc/default/kubelet | tail -n 1 \
      | sed 's/^"//; s/"$//; s/^'\''//; s/'\''$//'
  )"
fi
cleaned_extra_args="$(
  printf '%s\n' "${existing_extra_args}" \
    | awk '
      {
        out = ""
        for (i = 1; i <= NF; i++) {
          token = $i
          if (token ~ /^--resolv-conf(=|$)/) {
            if (token == "--resolv-conf" && i < NF && $(i + 1) !~ /^--/) {
              i++
            }
            continue
          }
          out = out (out ? " " : "") token
        }
        print out
      }
    '
)"
if [[ -n "${cleaned_extra_args}" ]]; then
  cleaned_extra_args="${cleaned_extra_args} --resolv-conf=${KUBELET_RESOLV_CONF}"
else
  cleaned_extra_args="--resolv-conf=${KUBELET_RESOLV_CONF}"
fi

tmp_kubelet_default="$(mktemp)"
if [[ -f /etc/default/kubelet ]]; then
  awk '!/^KUBELET_EXTRA_ARGS=/' /etc/default/kubelet > "${tmp_kubelet_default}"
fi
printf 'KUBELET_EXTRA_ARGS="%s"\n' "${cleaned_extra_args}" >> "${tmp_kubelet_default}"
cat "${tmp_kubelet_default}" > /etc/default/kubelet
rm -f "${tmp_kubelet_default}"

if command -v ufw >/dev/null 2>&1; then
  if [[ -f /etc/default/ufw ]]; then
    if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
      sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
    else
      printf '\nDEFAULT_FORWARD_POLICY="ACCEPT"\n' >> /etc/default/ufw
    fi
  fi
  ufw allow "${KUBELET_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${KUBE_PROXY_HEALTHZ_PORT}/tcp" >/dev/null 2>&1 || true
  ufw reload >/dev/null 2>&1 || true
fi

if [[ "${SKIP_CONTAINERD_RESTART}" -eq 0 ]] && systemctl list-unit-files | grep -q '^containerd.service'; then
  systemctl restart containerd
fi
if systemctl list-unit-files | grep -q '^kubelet.service'; then
  systemctl daemon-reload
  systemctl restart kubelet
fi

for _ in $(seq 1 30); do
  if ss -ltn "( sport = :${KUBELET_PORT} )" | grep -q ":${KUBELET_PORT}"; then
    break
  fi
  sleep 2
done

if ! ss -ltn "( sport = :${KUBELET_PORT} )" | grep -q ":${KUBELET_PORT}"; then
  die "kubelet port ${KUBELET_PORT} is not listening after restart."
fi

if getent hosts registry-1.docker.io >/dev/null 2>&1; then
  log "DNS probe ok: registry-1.docker.io resolved."
else
  log "WARNING: DNS probe failed for registry-1.docker.io (may be expected in fully offline mode)."
fi

log "Applied fixes: kubelet(:${KUBELET_PORT}) + resolver(${DNS_SERVERS})"
