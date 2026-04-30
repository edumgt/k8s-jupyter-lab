#!/usr/bin/env bash
set -euo pipefail

CONTROL_PLANE_IP="${1:-}"
TOKEN_TTL="${TOKEN_TTL:-2h}"

if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  CONTROL_PLANE_IP="$(hostname -I | awk '{print $1}')"
fi

if [[ -z "${CONTROL_PLANE_IP}" ]]; then
  printf 'Unable to resolve control-plane IP. Pass it explicitly: bash scripts/generate_join_command.sh <ip>\n' >&2
  exit 1
fi

TOKEN="$(kubeadm token create --ttl "${TOKEN_TTL}")"
CA_HASH="$(
  openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
    | openssl rsa -pubin -outform der 2>/dev/null \
    | openssl dgst -sha256 -hex \
    | awk '{print $NF}'
)"

printf 'kubeadm join %s:6443 --token %s --discovery-token-ca-cert-hash sha256:%s\n' \
  "${CONTROL_PLANE_IP}" \
  "${TOKEN}" \
  "${CA_HASH}"
