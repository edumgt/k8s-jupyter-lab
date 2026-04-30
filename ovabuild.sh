#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"

PACKER_VARS="${PACKER_VARS:-${PACKER_DIR}/variables.vmware.auto.pkrvars.hcl}"
DIST_DIR="${DIST_DIR:-C:/ffmpeg}"
CONTROL_PLANE_NAME="${CONTROL_PLANE_NAME:-k8s-data-platform}"
WORKER1_NAME="${WORKER1_NAME:-k8s-worker-1}"
WORKER2_NAME="${WORKER2_NAME:-k8s-worker-2}"
WORKER3_NAME="${WORKER3_NAME:-k8s-worker-3}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
REMOTE_HOME_REPO_ROOT="${REMOTE_HOME_REPO_ROOT:-/home/Kubernetes-Jupyter-Sandbox}"

CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-}"
INGRESS_LB_IP="${INGRESS_LB_IP:-}"
REMOTE_REPO_ROOT="${REMOTE_REPO_ROOT:-/opt/k8s-data-platform}"

POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
VMRUN_WIN="${VMRUN_WIN:-}"
OVFTOOL_WIN="${OVFTOOL_WIN:-}"
PACKER_EXE_WIN="${PACKER_EXE_WIN:-}"

SSH_USER="${SSH_USER:-}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY_PATH="${SSH_KEY_PATH:-}"
SSH_PORT="${SSH_PORT:-22}"
WAIT_VM_IP_TIMEOUT_SEC="${WAIT_VM_IP_TIMEOUT_SEC:-600}"

SKIP_PRECHECK=0
SKIP_SHA256=0
STRICT_HARBOR_CHECK=0
SKIP_REPO_COPY=0
SKIP_HARBOR_IMAGE_CHECK=0

log() {
  printf '[ovabuild.sh] %s\n' "$*"
}

die() {
  printf '[ovabuild.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash ovabuild.sh [options]

Role-specific OVA build flow for existing VMware VMs:
  1) (default) Pre-check current cluster/web endpoints with vmware_post_reboot_verify.sh
  2) Copy repo to VM home path + run pre-export Kubernetes/Harbor checks
  3) Stop each VM and export 4 OVA files (control-plane, worker-1, worker-2, worker-3)
  4) Generate SHA256 manifest for transfer/import validation

Options:
  --vars-file PATH             Packer vars file (default: packer/variables.vmware.auto.pkrvars.hcl)
  --dist-dir PATH              OVA output directory (default: C:/ffmpeg)
  --control-plane-name NAME    Default: k8s-data-platform
  --worker1-name NAME          Default: k8s-worker-1
  --worker2-name NAME          Default: k8s-worker-2
  --worker3-name NAME          Default: k8s-worker-3
  --env dev|prod               Default: dev

  --control-plane-ip IP        Optional static control-plane IP for pre-check
  --ingress-lb-ip IP           Optional fixed ingress LB IP for pre-check
  --remote-repo-root PATH      Default: /opt/k8s-data-platform
  --remote-home-repo-root PATH Default: /home/Kubernetes-Jupyter-Sandbox

  --ssh-user USER              SSH user for pre-check (optional)
  --ssh-password PASS          SSH password for pre-check (optional)
  --ssh-key-path PATH          SSH key path for pre-check (optional)
  --ssh-port PORT              SSH port for pre-check (default: 22)
  --wait-vm-ip-timeout-sec N   VM IP wait timeout for pre-check (default: 600)

  --skip-precheck              Skip pre-check and export immediately
  --skip-sha256                Skip SHA256 manifest generation
  --strict-harbor-check        Fail pre-check when Harbor(NodePort 30092) is unreachable
  --skip-repo-copy             Skip repo copy to VM home path before export
  --skip-harbor-image-check    Skip harbor image checks before export

  --vmrun PATH                 vmrun.exe path override
  --ovftool PATH               ovftool.exe path override
  --packer-exe PATH            packer.exe path override
  --powershell-bin CMD         PowerShell binary (default: powershell.exe)

  -h, --help                   Show this help

Examples:
  bash ./ovabuild.sh \
    --vars-file packer/variables.vmware.auto.pkrvars.hcl \
    --control-plane-ip 192.168.56.10 \
    --ingress-lb-ip 192.168.56.240 \
    --dist-dir C:/ffmpeg
EOF
}

is_windows_style_path() {
  [[ "$1" =~ ^[A-Za-z]:[\\/].* ]]
}

to_unix_path() {
  local path="$1"
  if is_windows_style_path "${path}"; then
    wslpath -u "${path}"
    return 0
  fi
  printf '%s' "${path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vars-file)
      [[ $# -ge 2 ]] || die "--vars-file requires a value"
      PACKER_VARS="$2"
      shift 2
      ;;
    --dist-dir)
      [[ $# -ge 2 ]] || die "--dist-dir requires a value"
      DIST_DIR="$2"
      shift 2
      ;;
    --control-plane-name)
      [[ $# -ge 2 ]] || die "--control-plane-name requires a value"
      CONTROL_PLANE_NAME="$2"
      shift 2
      ;;
    --worker1-name)
      [[ $# -ge 2 ]] || die "--worker1-name requires a value"
      WORKER1_NAME="$2"
      shift 2
      ;;
    --worker2-name)
      [[ $# -ge 2 ]] || die "--worker2-name requires a value"
      WORKER2_NAME="$2"
      shift 2
      ;;
    --worker3-name)
      [[ $# -ge 2 ]] || die "--worker3-name requires a value"
      WORKER3_NAME="$2"
      shift 2
      ;;
    --env)
      [[ $# -ge 2 ]] || die "--env requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --control-plane-ip)
      [[ $# -ge 2 ]] || die "--control-plane-ip requires a value"
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --ingress-lb-ip)
      [[ $# -ge 2 ]] || die "--ingress-lb-ip requires a value"
      INGRESS_LB_IP="$2"
      shift 2
      ;;
    --remote-repo-root)
      [[ $# -ge 2 ]] || die "--remote-repo-root requires a value"
      REMOTE_REPO_ROOT="$2"
      shift 2
      ;;
    --remote-home-repo-root)
      [[ $# -ge 2 ]] || die "--remote-home-repo-root requires a value"
      REMOTE_HOME_REPO_ROOT="$2"
      shift 2
      ;;
    --ssh-user)
      [[ $# -ge 2 ]] || die "--ssh-user requires a value"
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-password)
      [[ $# -ge 2 ]] || die "--ssh-password requires a value"
      SSH_PASSWORD="$2"
      shift 2
      ;;
    --ssh-key-path)
      [[ $# -ge 2 ]] || die "--ssh-key-path requires a value"
      SSH_KEY_PATH="$2"
      shift 2
      ;;
    --ssh-port)
      [[ $# -ge 2 ]] || die "--ssh-port requires a value"
      SSH_PORT="$2"
      shift 2
      ;;
    --wait-vm-ip-timeout-sec)
      [[ $# -ge 2 ]] || die "--wait-vm-ip-timeout-sec requires a value"
      WAIT_VM_IP_TIMEOUT_SEC="$2"
      shift 2
      ;;
    --skip-precheck)
      SKIP_PRECHECK=1
      shift
      ;;
    --skip-sha256)
      SKIP_SHA256=1
      shift
      ;;
    --strict-harbor-check)
      STRICT_HARBOR_CHECK=1
      shift
      ;;
    --skip-repo-copy)
      SKIP_REPO_COPY=1
      shift
      ;;
    --skip-harbor-image-check)
      SKIP_HARBOR_IMAGE_CHECK=1
      shift
      ;;
    --vmrun)
      [[ $# -ge 2 ]] || die "--vmrun requires a value"
      VMRUN_WIN="$2"
      shift 2
      ;;
    --ovftool)
      [[ $# -ge 2 ]] || die "--ovftool requires a value"
      OVFTOOL_WIN="$2"
      shift 2
      ;;
    --packer-exe)
      [[ $# -ge 2 ]] || die "--packer-exe requires a value"
      PACKER_EXE_WIN="$2"
      shift 2
      ;;
    --powershell-bin)
      [[ $# -ge 2 ]] || die "--powershell-bin requires a value"
      POWERSHELL_BIN="$2"
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

CONTROL_PLANE_SSH_HOST="${CONTROL_PLANE_IP}"

if [[ "${SKIP_PRECHECK}" -eq 0 ]]; then
  log "Step 1/4: Pre-check current VM/Kubernetes/web 상태"
  precheck_cmd=(
    bash "${ROOT_DIR}/scripts/vmware_post_reboot_verify.sh"
    --vars-file "${PACKER_VARS}"
    --control-plane-name "${CONTROL_PLANE_NAME}"
    --worker1-name "${WORKER1_NAME}"
    --worker2-name "${WORKER2_NAME}"
    --worker3-name "${WORKER3_NAME}"
    --env "${ENVIRONMENT}"
    --remote-repo-root "${REMOTE_REPO_ROOT}"
    --ssh-port "${SSH_PORT}"
    --wait-vm-ip-timeout-sec "${WAIT_VM_IP_TIMEOUT_SEC}"
    --powershell-bin "${POWERSHELL_BIN}"
    --skip-gitlab-clone-check
  )
  if [[ -n "${CONTROL_PLANE_IP}" ]]; then
    precheck_cmd+=(--control-plane-ip "${CONTROL_PLANE_IP}")
  fi
  if [[ -n "${INGRESS_LB_IP}" ]]; then
    precheck_cmd+=(--ingress-lb-ip "${INGRESS_LB_IP}")
  fi
  if [[ -n "${SSH_USER}" ]]; then
    precheck_cmd+=(--ssh-user "${SSH_USER}")
  fi
  if [[ -n "${SSH_PASSWORD}" ]]; then
    precheck_cmd+=(--ssh-password "${SSH_PASSWORD}")
  fi
  if [[ -n "${SSH_KEY_PATH}" ]]; then
    precheck_cmd+=(--ssh-key-path "${SSH_KEY_PATH}")
  fi
  if [[ -n "${VMRUN_WIN}" ]]; then
    precheck_cmd+=(--vmrun "${VMRUN_WIN}")
  fi
  if [[ "${STRICT_HARBOR_CHECK}" -eq 1 ]]; then
    precheck_cmd+=(--strict-harbor-check)
  fi

  precheck_log="$(mktemp)"
  if ! "${precheck_cmd[@]}" | tee "${precheck_log}"; then
    rm -f "${precheck_log}"
    die "Pre-check failed."
  fi
  if [[ -z "${CONTROL_PLANE_SSH_HOST}" ]]; then
    CONTROL_PLANE_SSH_HOST="$(
      awk -F': ' '/Control-plane SSH endpoint:/ { print $NF; exit }' "${precheck_log}" | tr -d '\r'
    )"
  fi
  rm -f "${precheck_log}"
else
  log "Step 1/4: Skipped pre-check (--skip-precheck)"
fi

[[ -n "${CONTROL_PLANE_SSH_HOST}" ]] || die "Unable to resolve control-plane SSH endpoint. Provide --control-plane-ip or run pre-check."

log "Step 2/4: Sync repo + pre-export Kubernetes/Harbor checks"
prepare_cmd=(
  bash "${ROOT_DIR}/scripts/vmware_pre_export_prepare.sh"
  --vars-file "${PACKER_VARS}"
  --control-plane-ip "${CONTROL_PLANE_SSH_HOST}"
  --control-plane-name "${CONTROL_PLANE_NAME}"
  --worker1-name "${WORKER1_NAME}"
  --worker2-name "${WORKER2_NAME}"
  --worker3-name "${WORKER3_NAME}"
  --env "${ENVIRONMENT}"
  --remote-repo-root "${REMOTE_REPO_ROOT}"
  --remote-home-repo-root "${REMOTE_HOME_REPO_ROOT}"
  --ssh-port "${SSH_PORT}"
)
if [[ -n "${SSH_USER}" ]]; then
  prepare_cmd+=(--ssh-user "${SSH_USER}")
fi
if [[ -n "${SSH_PASSWORD}" ]]; then
  prepare_cmd+=(--ssh-password "${SSH_PASSWORD}")
fi
if [[ -n "${SSH_KEY_PATH}" ]]; then
  prepare_cmd+=(--ssh-key-path "${SSH_KEY_PATH}")
fi
if [[ "${SKIP_REPO_COPY}" -eq 1 ]]; then
  prepare_cmd+=(--skip-repo-copy)
fi
if [[ "${SKIP_HARBOR_IMAGE_CHECK}" -eq 1 ]]; then
  prepare_cmd+=(--skip-harbor-image-check)
fi
"${prepare_cmd[@]}"

log "Step 3/4: Exporting role-specific OVAs (control-plane + 3 workers, VM stop included)"
export_cmd=(
  bash "${ROOT_DIR}/scripts/vmware_export_3node_ova.sh"
  --vars-file "${PACKER_VARS}"
  --dist-dir "${DIST_DIR}"
  --control-plane-name "${CONTROL_PLANE_NAME}"
  --worker1-name "${WORKER1_NAME}"
  --worker2-name "${WORKER2_NAME}"
  --worker3-name "${WORKER3_NAME}"
)
if [[ -n "${VMRUN_WIN}" ]]; then
  export_cmd+=(--vmrun "${VMRUN_WIN}")
fi
if [[ -n "${OVFTOOL_WIN}" ]]; then
  export_cmd+=(--ovftool "${OVFTOOL_WIN}")
fi
if [[ -n "${PACKER_EXE_WIN}" ]]; then
  export_cmd+=(--packer-exe "${PACKER_EXE_WIN}")
fi

"${export_cmd[@]}"

if [[ "${SKIP_SHA256}" -eq 0 ]]; then
  log "Step 4/4: Generating OVA SHA256 manifest"
  DIST_DIR_UNIX="$(to_unix_path "${DIST_DIR}")"
  mkdir -p "${DIST_DIR_UNIX}"

  cp_ova="${DIST_DIR_UNIX}/${CONTROL_PLANE_NAME}.ova"
  w1_ova="${DIST_DIR_UNIX}/${WORKER1_NAME}.ova"
  w2_ova="${DIST_DIR_UNIX}/${WORKER2_NAME}.ova"
  w3_ova="${DIST_DIR_UNIX}/${WORKER3_NAME}.ova"
  [[ -f "${cp_ova}" ]] || die "Missing OVA artifact: ${cp_ova}"
  [[ -f "${w1_ova}" ]] || die "Missing OVA artifact: ${w1_ova}"
  [[ -f "${w2_ova}" ]] || die "Missing OVA artifact: ${w2_ova}"
  [[ -f "${w3_ova}" ]] || die "Missing OVA artifact: ${w3_ova}"

  manifest_path="${DIST_DIR_UNIX}/ova-sha256.txt"
  (
    cd "${DIST_DIR_UNIX}"
    sha256sum "${CONTROL_PLANE_NAME}.ova" "${WORKER1_NAME}.ova" "${WORKER2_NAME}.ova" "${WORKER3_NAME}.ova" > "${manifest_path}"
  )
  log "SHA256 manifest: ${manifest_path}"
else
  log "Step 4/4: Skipped SHA256 manifest (--skip-sha256)"
fi

log "Completed."
log "Import test on target PC:"
log "  1) Copy 4 OVA + ova-sha256.txt"
log "  2) Verify checksum on target PC"
log "  3) Import 4 VMs in VMware (control-plane, worker-1, worker-2, worker-3)"
log "  4) Power on VMs and run: bash scripts/vmware_post_reboot_verify.sh --vars-file ${PACKER_VARS} --control-plane-ip <CP_IP> --ingress-lb-ip <LB_IP>"
