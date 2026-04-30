#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/scripts/lib/vm_base_packages.sh"

BUNDLE_DIR="${BUNDLE_DIR:-${ROOT_DIR}/dist/vm-apt-bundle}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
ARCH="${ARCH:-amd64}"

usage() {
  cat <<'EOF'
Usage: bash scripts/prepare_vm_apt_bundle.sh [options]

Builds an offline .deb bundle for the base VM utility packages using an Ubuntu
container that matches the target VM release.

Options:
  --out-dir PATH         Output bundle directory.
  --ubuntu-image IMAGE   Ubuntu container image to use (default: ubuntu:24.04).
  --arch ARCH            apt architecture (default: amd64).
  -h, --help             Show this help.
EOF
}

log() {
  printf '[%s] %s\n' "$(basename "$0")" "$*"
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --ubuntu-image)
      UBUNTU_IMAGE="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
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

require_command docker
mkdir -p "${BUNDLE_DIR}/deb"

package_list="$(vm_base_packages_joined)"
package_list="${package_list% }"

log "Preparing offline apt bundle in ${BUNDLE_DIR}"
docker run --rm \
  -v "${BUNDLE_DIR}:/bundle" \
  "${UBUNTU_IMAGE}" \
  bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends apt-utils ca-certificates
    mkdir -p /bundle/deb
    apt-get install -y --download-only --no-install-recommends ${package_list}
    cp -a /var/cache/apt/archives/*.deb /bundle/deb/
  "

cat > "${BUNDLE_DIR}/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
bundle_dir="/opt/k8s-data-platform/vm-apt-bundle/deb"
dpkg -i "${bundle_dir}"/*.deb || true
apt-get -o Acquire::Retries=0 --no-download install -f -y
systemctl enable vsftpd >/dev/null 2>&1 || true
systemctl restart vsftpd >/dev/null 2>&1 || true
java -version >/dev/null 2>&1
python3 --version >/dev/null 2>&1
EOF
chmod +x "${BUNDLE_DIR}/install.sh"

printf '%s\n' "${package_list}" | tr ' ' '\n' > "${BUNDLE_DIR}/packages.txt"
find "${BUNDLE_DIR}/deb" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort > "${BUNDLE_DIR}/package-versions.txt"
log "Offline apt bundle ready: ${BUNDLE_DIR}"
