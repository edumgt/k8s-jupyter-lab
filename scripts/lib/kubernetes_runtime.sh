#!/usr/bin/env bash

require_runtime_importer() {
  command -v ctr >/dev/null 2>&1 || {
    printf 'Required command not found: ctr\n' >&2
    return 1
  }
}

import_archive_into_runtime() {
  local archive="$1"

  if command -v sudo >/dev/null 2>&1; then
    sudo ctr -n k8s.io images import "${archive}"
    return
  fi

  ctr -n k8s.io images import "${archive}"
}

print_runtime_import_cmd() {
  local archive="$1"

  if command -v sudo >/dev/null 2>&1; then
    printf '+ %q %q %q %q %q %q\n' sudo ctr -n k8s.io images import "${archive}"
    return
  fi

  printf '+ %q %q %q %q %q\n' ctr -n k8s.io images import "${archive}"
}

run_kubectl() {
  if kubectl "$@" 2>/dev/null; then
    return 0
  fi

  if [[ -f /etc/kubernetes/admin.conf ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo env KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
      return $?
    fi

    env KUBECONFIG=/etc/kubernetes/admin.conf kubectl "$@"
    return $?
  fi

  kubectl "$@"
}

kubernetes_services_ready() {
  systemctl is-active --quiet containerd
  systemctl is-active --quiet kubelet
}

show_kubernetes_service_status() {
  printf '[containerd]\n'
  systemctl --no-pager --full status containerd | sed -n '1,40p'
  printf '\n[kubelet]\n'
  systemctl --no-pager --full status kubelet | sed -n '1,40p'
}
