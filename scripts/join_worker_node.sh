#!/usr/bin/env bash
set -euo pipefail

WORKER_HOSTNAME=""
JOIN_COMMAND=""
JOIN_COMMAND_B64=""
CRI_SOCKET="unix:///run/containerd/containerd.sock"
SKIP_RESET=0

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/join_worker_node.sh [options]

Options:
  --hostname <name>           Worker node hostname (recommended).
  --join-command <string>     Raw kubeadm join command.
  --join-command-b64 <base64> Base64 encoded kubeadm join command.
  --cri-socket <socket>       CRI socket path. Defaults to unix:///run/containerd/containerd.sock.
  --skip-reset                Skip kubeadm reset/cleanup stage.
  -h, --help                  Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root or with sudo."
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      [[ $# -ge 2 ]] || die "--hostname requires a value"
      WORKER_HOSTNAME="$2"
      shift 2
      ;;
    --join-command)
      [[ $# -ge 2 ]] || die "--join-command requires a value"
      JOIN_COMMAND="$2"
      shift 2
      ;;
    --join-command-b64)
      [[ $# -ge 2 ]] || die "--join-command-b64 requires a value"
      JOIN_COMMAND_B64="$2"
      shift 2
      ;;
    --cri-socket)
      [[ $# -ge 2 ]] || die "--cri-socket requires a value"
      CRI_SOCKET="$2"
      shift 2
      ;;
    --skip-reset)
      SKIP_RESET=1
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

if [[ -n "${JOIN_COMMAND_B64}" ]]; then
  JOIN_COMMAND="$(printf '%s' "${JOIN_COMMAND_B64}" | base64 -d)"
fi

[[ -n "${JOIN_COMMAND}" ]] || die "Provide --join-command or --join-command-b64."

if [[ "${JOIN_COMMAND}" != kubeadm\ join* ]]; then
  die "join command must start with 'kubeadm join'."
fi

if [[ "${JOIN_COMMAND}" != *"--cri-socket"* ]]; then
  JOIN_COMMAND="${JOIN_COMMAND} --cri-socket=${CRI_SOCKET}"
fi

if [[ -n "${WORKER_HOSTNAME}" ]]; then
  hostnamectl set-hostname "${WORKER_HOSTNAME}"
fi

if [[ "${SKIP_RESET}" == "0" ]]; then
  kubeadm reset -f --cri-socket="${CRI_SOCKET}" || true
  rm -rf /etc/cni/net.d /etc/kubernetes/pki /var/lib/etcd || true
  systemctl restart containerd
  systemctl restart kubelet
fi

bash -lc "${JOIN_COMMAND}"
