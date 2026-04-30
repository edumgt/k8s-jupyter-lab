#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

record_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf 'ok - %s\n' "$1"
}

record_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'not ok - %s\n' "$1" >&2
}

assert_file_exists() {
  [[ -f "$1" ]] || {
    printf 'expected file to exist: %s\n' "$1" >&2
    return 1
  }
}

assert_log_contains() {
  local file="$1"
  local pattern="$2"

  grep -F "${pattern}" "${file}" >/dev/null || {
    printf 'expected log to contain: %s\n' "${pattern}" >&2
    printf 'log file: %s\n' "${file}" >&2
    return 1
  }
}

make_fixture_repo() {
  local target="$1"

  mkdir -p "${target}/scripts" "${target}/packer"
  cp "${REPO_ROOT}/scripts/build_ova.sh" "${target}/scripts/build_ova.sh"
  cp "${REPO_ROOT}/scripts/run_wsl.sh" "${target}/scripts/run_wsl.sh"
  chmod +x "${target}/scripts/build_ova.sh" "${target}/scripts/run_wsl.sh"
}

test_build_ova_supports_windows_style_ovftool_path() (
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  make_fixture_repo "${tmp_dir}"
  mkdir -p "${tmp_dir}/packer/output-k8s-data-platform" "${tmp_dir}/bin"
  : > "${tmp_dir}/packer/output-k8s-data-platform/k8s-data-platform.vmx"

  cat > "${tmp_dir}/packer/variables.pkr.hcl" <<'EOF'
vm_name = "k8s-data-platform"
output_directory = "output-k8s-data-platform"
ovftool_path_windows = "C:\Tools\VMware OVF Tool\ovftool.exe"
EOF

  cat > "${tmp_dir}/bin/wslpath" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-u" ]]; then
  if [[ "\$2" == 'C:\Tools\VMware OVF Tool\ovftool.exe' ]]; then
    printf '%s\n' '${tmp_dir}/bin/ovftool.exe'
    exit 0
  fi
  if [[ "\$2" == 'C:\ffmpeg\packer-cache' ]]; then
    printf '%s\n' '${tmp_dir}/packer-cache'
    exit 0
  fi
  printf '%s\n' '${tmp_dir}/wslpath-u-fallback'
  exit 0
fi
if [[ "\$1" == "-w" ]]; then
  printf '%s\n' "\$2"
  exit 0
fi
exit 1
EOF

  cat > "${tmp_dir}/bin/ovftool.exe" <<'EOF'
#!/usr/bin/env bash
touch "$4"
EOF

  chmod +x "${tmp_dir}/bin/wslpath" "${tmp_dir}/bin/ovftool.exe"
  PATH="${tmp_dir}/bin:${PATH}" DIST_DIR="${tmp_dir}/dist" bash "${tmp_dir}/scripts/build_ova.sh"

  assert_file_exists "${tmp_dir}/dist/k8s-data-platform.ova"
)

test_run_wsl_executes_build_and_export_flow() (
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' EXIT

  make_fixture_repo "${tmp_dir}"
  mkdir -p "${tmp_dir}/bin"

  cat > "${tmp_dir}/packer/variables.pkr.hcl" <<'EOF'
vm_name = "k8s-data-platform"
output_directory = "output-k8s-data-platform"
ovftool_path_windows = "C:\Tools\VMware OVF Tool\ovftool.exe"
EOF

  cat > "${tmp_dir}/bin/packer" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '${tmp_dir}/packer.log'
case "\$1" in
  init|validate)
    exit 0
    ;;
  build)
    mkdir -p output-k8s-data-platform
    : > output-k8s-data-platform/k8s-data-platform.vmx
    exit 0
    ;;
esac
exit 1
EOF

  cat > "${tmp_dir}/bin/wslpath" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-u" ]]; then
  if [[ "\$2" == 'C:\Tools\VMware OVF Tool\ovftool.exe' ]]; then
    printf '%s\n' '${tmp_dir}/bin/ovftool.exe'
    exit 0
  fi
  if [[ "\$2" == 'C:\ffmpeg\packer-cache' ]]; then
    printf '%s\n' '${tmp_dir}/packer-cache'
    exit 0
  fi
  printf '%s\n' '${tmp_dir}/wslpath-u-fallback'
  exit 0
fi
if [[ "\$1" == "-w" ]]; then
  printf '%s\n' "\$2"
  exit 0
fi
exit 1
EOF

  cat > "${tmp_dir}/bin/ovftool.exe" <<'EOF'
#!/usr/bin/env bash
touch "$4"
EOF

  run_log="${tmp_dir}/run_wsl.log"
  chmod +x "${tmp_dir}/bin/packer" "${tmp_dir}/bin/wslpath" "${tmp_dir}/bin/ovftool.exe"
  if ! PATH="${tmp_dir}/bin:${PATH}" PACKER_BIN="${tmp_dir}/bin/packer" DIST_DIR="${tmp_dir}/dist" bash "${tmp_dir}/scripts/run_wsl.sh" --vars-file "${tmp_dir}/packer/variables.pkr.hcl" >"${run_log}" 2>&1; then
    cat "${run_log}" >&2
    return 1
  fi

  assert_log_contains "${tmp_dir}/packer.log" "init ."
  assert_log_contains "${tmp_dir}/packer.log" "validate -var-file=${tmp_dir}/packer/variables.pkr.hcl k8s-data-platform.pkr.hcl"
  assert_log_contains "${tmp_dir}/packer.log" "build -var-file=${tmp_dir}/packer/variables.pkr.hcl k8s-data-platform.pkr.hcl"
  assert_file_exists "${tmp_dir}/dist/k8s-data-platform.ova"
)

run_test() {
  local name="$1"

  if "${name}"; then
    record_pass "${name}"
  else
    record_fail "${name}"
  fi
}

run_test test_build_ova_supports_windows_style_ovftool_path
run_test test_run_wsl_executes_build_and_export_flow

if [[ "${TESTS_FAILED}" -ne 0 ]]; then
  printf '%s tests failed\n' "${TESTS_FAILED}" >&2
  exit 1
fi

printf '%s tests passed\n' "${TESTS_PASSED}"
