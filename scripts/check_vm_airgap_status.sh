#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/kubernetes/admin.conf}"
EXPECTED_NODES="${EXPECTED_NODES:-k8s-data-platform,k8s-worker-1,k8s-worker-2,k8s-worker-3}"
WAIT_TIMEOUT_SEC="${WAIT_TIMEOUT_SEC:-1200}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-10}"
LOG_DIR="${LOG_DIR:-/var/log/k8s-data-platform}"
EXTERNAL_REGISTRY_PATTERN="${EXTERNAL_REGISTRY_PATTERN:-docker\\.io|ghcr\\.io|quay\\.io}"
EXIT_CODE=0

log() {
  printf '[check_vm_airgap_status.sh] %s\n' "$*"
}

warn() {
  printf '[check_vm_airgap_status.sh] WARNING: %s\n' "$*" >&2
  EXIT_CODE=1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "Required command not found: $1"
    return 1
  }
}

prepare_log() {
  local timestamp
  local log_file

  timestamp="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  if [[ -w "${LOG_DIR}" ]]; then
    log_file="${LOG_DIR}/vm-airgap-check-${timestamp}.log"
    exec > >(tee -a "${log_file}") 2>&1
    log "Log file: ${log_file}"
  else
    warn "Cannot write to LOG_DIR=${LOG_DIR}; only stdout/stderr logging will be used."
  fi
}

run_kubectl() {
  if [[ "${EUID}" -eq 0 ]]; then
    KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"
    return
  fi

  sudo env KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"
}

wait_for_cluster_api() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))

  until run_kubectl get nodes >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      warn "Timed out waiting for Kubernetes API: ${KUBECONFIG_PATH}"
      return 1
    fi
    log "Waiting for Kubernetes API..."
    sleep "${POLL_INTERVAL_SEC}"
  done

  log "Kubernetes API is reachable."
}

wait_for_expected_nodes_ready() {
  local deadline=$((SECONDS + WAIT_TIMEOUT_SEC))
  local not_ready
  local missing
  local node
  local ready
  local ready_nodes
  local expected_count
  IFS=',' read -r -a nodes <<< "${EXPECTED_NODES}"

  while true; do
    not_ready=()
    missing=()
    ready_nodes=0
    expected_count=0

    for node in "${nodes[@]}"; do
      node="${node// /}"
      [[ -n "${node}" ]] || continue
      expected_count=$((expected_count + 1))

      ready="$(run_kubectl get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
      if [[ -z "${ready}" ]]; then
        missing+=("${node}")
        continue
      fi
      if [[ "${ready}" == "True" ]]; then
        ready_nodes=$((ready_nodes + 1))
      else
        not_ready+=("${node}:${ready}")
      fi
    done

    if (( expected_count > 0 )) && (( ready_nodes == expected_count )) && (( ${#missing[@]} == 0 )) && (( ${#not_ready[@]} == 0 )); then
      log "All expected nodes are Ready: ${EXPECTED_NODES}"
      return 0
    fi

    if (( SECONDS >= deadline )); then
      warn "Timed out waiting expected nodes to be Ready."
      if (( ${#missing[@]} > 0 )); then
        warn "Missing nodes: ${missing[*]}"
      fi
      if (( ${#not_ready[@]} > 0 )); then
        warn "NotReady nodes: ${not_ready[*]}"
      fi
      return 1
    fi

    log "Waiting nodes Ready (expected=${EXPECTED_NODES})..."
    sleep "${POLL_INTERVAL_SEC}"
  done
}

check_node_and_pod_snapshot() {
  log "Node snapshot:"
  run_kubectl get nodes -o wide || warn "Failed to get nodes."

  log "Pod snapshot (all namespaces):"
  run_kubectl get pods -A -o wide || warn "Failed to get pods."
}

check_pull_errors() {
  local bad_pods
  local pull_events

  bad_pods="$(
    run_kubectl get pods -A --no-headers 2>/dev/null \
      | awk '$4 ~ /ImagePullBackOff|ErrImagePull/ { print $1 "/" $2 " status=" $4 }' || true
  )"
  if [[ -n "${bad_pods}" ]]; then
    warn "Pods in ImagePullBackOff/ErrImagePull:"
    printf '%s\n' "${bad_pods}" >&2
  else
    log "No pods in ImagePullBackOff/ErrImagePull."
  fi

  pull_events="$(
    run_kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null \
      | grep -Ei 'Failed to pull image|ImagePullBackOff|ErrImagePull' || true
  )"
  if [[ -n "${pull_events}" ]]; then
    log "Recent image pull related events detected (informational):"
    printf '%s\n' "${pull_events}" | tail -n 20
  else
    log "No recent image pull related events."
  fi
}

check_external_registry_refs() {
  local pod_refs
  local workload_refs

  pod_refs="$(
    run_kubectl get pods -A \
      -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,IMAGE:.spec.containers[*].image \
      --no-headers 2>/dev/null \
      | awk '$3 ~ /Running|Pending|Unknown/' \
      | grep -Ei "${EXTERNAL_REGISTRY_PATTERN}" || true
  )"

  workload_refs="$(
    run_kubectl get ds,deploy,statefulset -A \
      -o custom-columns=KIND:.kind,NS:.metadata.namespace,NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image \
      --no-headers 2>/dev/null \
      | grep -Ei "${EXTERNAL_REGISTRY_PATTERN}" || true
  )"

  if [[ -n "${pod_refs}" ]]; then
    warn "External registry refs found in running pods:"
    printf '%s\n' "${pod_refs}" >&2
  else
    log "No external registry refs in running pod images."
  fi

  if [[ -n "${workload_refs}" ]]; then
    warn "External registry refs found in workload specs (ds/deploy/statefulset):"
    printf '%s\n' "${workload_refs}" >&2
  else
    log "No external registry refs in workload specs."
  fi
}

main() {
  prepare_log

  require_command kubectl || exit 1
  require_command awk || exit 1
  require_command grep || exit 1
  require_command date || exit 1
  require_command tee || exit 1

  if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    warn "Kubeconfig not found: ${KUBECONFIG_PATH}"
    exit "${EXIT_CODE}"
  fi

  wait_for_cluster_api || true
  wait_for_expected_nodes_ready || true
  check_node_and_pod_snapshot
  check_pull_errors
  check_external_registry_refs

  if [[ "${EXIT_CODE}" -eq 0 ]]; then
    log "VM air-gap check completed: PASS"
  else
    warn "VM air-gap check completed: FAIL"
  fi
  exit "${EXIT_CODE}"
}

main "$@"
