#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="${ROOT_DIR}/scripts/build_ova.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  local path="$1"
  [[ -f "${path}" ]] || fail "Expected file to exist: ${path}"
}

assert_contains() {
  local file="$1"
  local pattern="$2"

  grep -F "${pattern}" "${file}" >/dev/null || fail "Expected '${pattern}' in ${file}"
}

make_fixture() {
  local fixture_dir
  fixture_dir="$(mktemp -d)"

  mkdir -p "${fixture_dir}/scripts" "${fixture_dir}/packer/output-k8s-data-platform" "${fixture_dir}/dist"
  cp "${SOURCE_SCRIPT}" "${fixture_dir}/scripts/build_ova.sh"
  chmod +x "${fixture_dir}/scripts/build_ova.sh"
  : > "${fixture_dir}/packer/output-k8s-data-platform/k8s-data-platform.vmx"

  echo "${fixture_dir}"
}

run_native_linux_test() {
  local fixture_dir="$1"
  local tool_dir="${fixture_dir}/tools"
  local tool_path="${tool_dir}/ovftool"
  local args_log="${fixture_dir}/native-args.log"

  mkdir -p "${tool_dir}"

  cat > "${tool_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "${args_log}"
: > "\$4"
EOF
  chmod +x "${tool_path}"

  cat > "${fixture_dir}/packer/variables.pkr.hcl" <<EOF
vm_name              = "k8s-data-platform"
output_directory     = "output-k8s-data-platform"
ovftool_path_windows = "${tool_path}"
EOF

  bash "${fixture_dir}/scripts/build_ova.sh" --dist-dir "${fixture_dir}/dist" >/tmp/test_build_ova_native.out

  assert_file "${fixture_dir}/dist/k8s-data-platform.ova"
  assert_contains "${args_log}" "${fixture_dir}/packer/output-k8s-data-platform/k8s-data-platform.vmx"
  assert_contains "${args_log}" "${fixture_dir}/dist/k8s-data-platform.ova"
}

run_wsl_windows_tool_test() {
  local fixture_dir="$1"
  local bin_dir="${fixture_dir}/bin"
  local tool_dir="${fixture_dir}/windows-tool"
  local tool_path="${tool_dir}/ovftool.exe"
  local args_log="${fixture_dir}/wsl-args.log"

  mkdir -p "${bin_dir}" "${tool_dir}"

  cat > "${bin_dir}/wslpath" <<EOF
#!/usr/bin/env bash
set -euo pipefail

case "\$1" in
  -u)
    if [[ "\$2" == 'C:\Program Files\VMware\VMware OVF Tool\ovftool.exe' ]]; then
      printf '%s\n' "${tool_path}"
      exit 0
    fi
    ;;
  -w)
    printf 'WIN:%s\n' "\$2"
    exit 0
    ;;
esac

echo "unexpected wslpath usage: \$*" >&2
exit 1
EOF
  chmod +x "${bin_dir}/wslpath"

  cat > "${tool_path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$@" > "${args_log}"
output_path="\${4#WIN:}"
: > "\${output_path}"
EOF
  chmod +x "${tool_path}"

  cat > "${fixture_dir}/packer/variables.pkr.hcl" <<'EOF'
vm_name              = "k8s-data-platform"
output_directory     = "output-k8s-data-platform"
ovftool_path_windows = "C:\Program Files\VMware\VMware OVF Tool\ovftool.exe"
EOF

  PATH="${bin_dir}:${PATH}" WSL_DISTRO_NAME="Ubuntu-Test" bash "${fixture_dir}/scripts/build_ova.sh" --dist-dir "${fixture_dir}/dist" >/tmp/test_build_ova_wsl.out

  assert_file "${fixture_dir}/dist/k8s-data-platform.ova"
  assert_contains "${args_log}" "WIN:${fixture_dir}/packer/output-k8s-data-platform/k8s-data-platform.vmx"
  assert_contains "${args_log}" "WIN:${fixture_dir}/dist/k8s-data-platform.ova"
}

main() {
  local native_fixture
  local wsl_fixture

  native_fixture="$(make_fixture)"
  wsl_fixture="$(make_fixture)"

  trap "rm -rf '${native_fixture}' '${wsl_fixture}'" EXIT

  run_native_linux_test "${native_fixture}"
  run_wsl_windows_tool_test "${wsl_fixture}"

  echo "PASS: build_ova.sh native and WSL path handling"
}

main "$@"
