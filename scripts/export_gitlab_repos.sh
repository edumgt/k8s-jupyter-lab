#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/dist/gitlab-repos}"
FORCE=0

usage() {
  cat <<'EOF'
Usage: bash scripts/export_gitlab_repos.sh [options]

Options:
  --out-dir <path>  Directory where the GitLab repo scaffolds will be written.
  --force           Remove an existing output directory before exporting.
  -h, --help        Show this help.
EOF
}

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      [[ $# -ge 2 ]] || die "--out-dir requires a value"
      OUT_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
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

clean_output_dir() {
  if [[ -d "${OUT_DIR}" ]]; then
    if [[ "${FORCE}" == "1" ]]; then
      rm -rf "${OUT_DIR}"
    else
      die "Output directory already exists: ${OUT_DIR} (use --force to replace it)"
    fi
  fi

  mkdir -p "${OUT_DIR}"
}

copy_app_contents() {
  local app_name="$1"
  local repo_dir="$2"

  mkdir -p "${repo_dir}"
  cp -R "${ROOT_DIR}/apps/${app_name}/." "${repo_dir}/"
  rm -rf "${repo_dir}/__pycache__" "${repo_dir}/node_modules" "${repo_dir}/dist"
}

write_repo_gitignore() {
  local repo_dir="$1"

  cat > "${repo_dir}/.gitignore" <<'EOF'
__pycache__/
.pytest_cache/
.mypy_cache/
.venv/
venv/
dist/
node_modules/
.DS_Store
kubeconfig
EOF
}

write_backend_ci() {
  local repo_dir="$1"

  cat > "${repo_dir}/.gitlab-ci.yml" <<'EOF'
stages:
  - build
  - deploy
  - verify

variables:
  HARBOR_REGISTRY: "harbor.local"
  HARBOR_PROJECT: "data-platform"
  IMAGE_NAME: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/k8s-data-platform-backend"
  NEXUS_PYPI_INDEX_URL: "http://192.168.56.10:30091/repository/pypi-all/simple"
  NEXUS_PYPI_TRUSTED_HOST: "192.168.56.10"
  DEPLOY_NAMESPACE: "data-platform-dev"
  TARGET_NODES: "192.168.56.10 192.168.56.11 192.168.56.12"
  SSH_USER: "ubuntu"
  SSH_PASSWORD: "ubuntu"
  INGRESS_LB_IP: "192.168.56.240"

workflow:
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev"'
      variables:
        DEPLOY_ENV: "dev"
        APP_ENV: "dev"
        BACKEND_HOST: "dev-api.platform.local"
    - if: '$CI_COMMIT_BRANCH == "prod"'
      variables:
        DEPLOY_ENV: "prod"
        APP_ENV: "prod"
        BACKEND_HOST: "api.platform.local"
    - when: never

build_backend_image:
  stage: build
  tags:
    - control-plane-shell
  script:
    - set -euo pipefail
    - test -n "${NEXUS_PYPI_INDEX_URL:-}" || (echo "NEXUS_PYPI_INDEX_URL is required" && exit 1)
    - echo "${NEXUS_PYPI_INDEX_URL}" | grep -Eq 'nexus\.platform\.local|127\.0\.0\.1:30091|192\.168\.56\.(10|240):30091' || (echo "NEXUS_PYPI_INDEX_URL must point to local Nexus" && exit 1)
    - docker build --build-arg "APP_ENV=${APP_ENV}" --build-arg "PIP_INDEX_URL=${NEXUS_PYPI_INDEX_URL}" --build-arg "PIP_TRUSTED_HOST=${NEXUS_PYPI_TRUSTED_HOST}" -t "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" -t "${IMAGE_NAME}:latest" .
    - TAR_PATH="/tmp/backend-${CI_PIPELINE_ID}-${CI_JOB_ID}.tar"
    - TAR_NAME="$(basename "${TAR_PATH}")"
    - docker save "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" -o "${TAR_PATH}"
    - |
      for node in ${TARGET_NODES}; do
        if [ "${node}" = "192.168.56.10" ]; then
          printf '%s\n' "${SSH_PASSWORD}" | sudo -S -p '' ctr -n k8s.io images import "${TAR_PATH}"
          continue
        fi
        sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${node}" \
          "printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' rm -f /tmp/${TAR_NAME}"
        sshpass -p "${SSH_PASSWORD}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${TAR_PATH}" "${SSH_USER}@${node}:/tmp/${TAR_NAME}"
        sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${node}" \
          "printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' ctr -n k8s.io images import /tmp/${TAR_NAME} && rm -f /tmp/${TAR_NAME}"
      done
    - rm -f "${TAR_PATH}"
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev" || $CI_COMMIT_BRANCH == "prod"'

deploy_backend:
  stage: deploy
  tags:
    - control-plane-shell
  needs:
    - build_backend_image
  script:
    - set -euo pipefail
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" set image deployment/backend backend="${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}"
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" rollout status deployment/backend --timeout=240s
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" get deploy backend -o wide
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" get pods -l app=backend -o wide
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev" || $CI_COMMIT_BRANCH == "prod"'

verify_backend_route:
  stage: verify
  tags:
    - control-plane-shell
  needs:
    - deploy_backend
  script:
    - set -euo pipefail
    - 'curl -fsS -I -H "Host: ${BACKEND_HOST}" "http://${INGRESS_LB_IP}/docs" | head -n 1'
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev" || $CI_COMMIT_BRANCH == "prod"'
EOF
}

write_frontend_ci() {
  local repo_dir="$1"

  cat > "${repo_dir}/.gitlab-ci.yml" <<'EOF'
stages:
  - build
  - deploy
  - verify

variables:
  HARBOR_REGISTRY: "harbor.local"
  HARBOR_PROJECT: "data-platform"
  IMAGE_NAME: "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/k8s-data-platform-frontend"
  NEXUS_NPM_REGISTRY: "http://192.168.56.10:30091/repository/npm-all/"
  DEPLOY_NAMESPACE: "data-platform-dev"
  TARGET_NODES: "192.168.56.10 192.168.56.11 192.168.56.12"
  SSH_USER: "ubuntu"
  SSH_PASSWORD: "ubuntu"
  INGRESS_LB_IP: "192.168.56.240"

workflow:
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev"'
      variables:
        DEPLOY_ENV: "dev"
        APP_ENV: "dev"
        VITE_API_BASE_URL: "http://dev-api.platform.local"
        FRONTEND_HOST: "dev.platform.local"
    - if: '$CI_COMMIT_BRANCH == "prod"'
      variables:
        DEPLOY_ENV: "prod"
        APP_ENV: "prod"
        VITE_API_BASE_URL: "http://api.platform.local"
        FRONTEND_HOST: "www.platform.local"
    - when: never

build_frontend_image:
  stage: build
  tags:
    - control-plane-shell
  script:
    - set -euo pipefail
    - test -n "${NEXUS_NPM_REGISTRY:-}" || (echo "NEXUS_NPM_REGISTRY is required" && exit 1)
    - echo "${NEXUS_NPM_REGISTRY}" | grep -Eq 'nexus\.platform\.local|127\.0\.0\.1:30091|192\.168\.56\.(10|240):30091' || (echo "NEXUS_NPM_REGISTRY must point to local Nexus" && exit 1)
    - |
      BUILD_ARGS=()
      BUILD_ARGS+=(--build-arg "APP_ENV=${APP_ENV}")
      BUILD_ARGS+=(--build-arg "NPM_REGISTRY=${NEXUS_NPM_REGISTRY}")
      if [ -n "${NEXUS_NPM_AUTH_B64:-}" ]; then
        BUILD_ARGS+=(--build-arg "NPM_AUTH_B64=${NEXUS_NPM_AUTH_B64}")
      fi
      docker build "${BUILD_ARGS[@]}" \
        --no-cache \
        --build-arg "VITE_API_BASE_URL=${VITE_API_BASE_URL}" \
        -t "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" \
        -t "${IMAGE_NAME}:latest" .
    - TAR_PATH="/tmp/frontend-${CI_PIPELINE_ID}-${CI_JOB_ID}.tar"
    - TAR_NAME="$(basename "${TAR_PATH}")"
    - docker save "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" -o "${TAR_PATH}"
    - |
      for node in ${TARGET_NODES}; do
        if [ "${node}" = "192.168.56.10" ]; then
          printf '%s\n' "${SSH_PASSWORD}" | sudo -S -p '' ctr -n k8s.io images import "${TAR_PATH}"
          continue
        fi
        sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${node}" \
          "printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' rm -f /tmp/${TAR_NAME}"
        sshpass -p "${SSH_PASSWORD}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${TAR_PATH}" "${SSH_USER}@${node}:/tmp/${TAR_NAME}"
        sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${SSH_USER}@${node}" \
          "printf '%s\n' '${SSH_PASSWORD}' | sudo -S -p '' ctr -n k8s.io images import /tmp/${TAR_NAME} && rm -f /tmp/${TAR_NAME}"
      done
    - rm -f "${TAR_PATH}"
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev" || $CI_COMMIT_BRANCH == "prod"'

deploy_frontend:
  stage: deploy
  tags:
    - control-plane-shell
  needs:
    - build_frontend_image
  script:
    - set -euo pipefail
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" set image deployment/frontend frontend="${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}"
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" rollout status deployment/frontend --timeout=240s
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" get deploy frontend -o wide
    - sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n "${DEPLOY_NAMESPACE}" get pods -l app=frontend -o wide
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev" || $CI_COMMIT_BRANCH == "prod"'

verify_frontend_route:
  stage: verify
  tags:
    - control-plane-shell
  needs:
    - deploy_frontend
  script:
    - set -euo pipefail
    - 'curl -fsS -I -H "Host: ${FRONTEND_HOST}" "http://${INGRESS_LB_IP}/" | head -n 1'
  rules:
    - if: '$CI_COMMIT_BRANCH == "dev" || $CI_COMMIT_BRANCH == "prod"'
EOF
}

write_airflow_ci() {
  local repo_dir="$1"

  cat > "${repo_dir}/.gitlab-ci.yml" <<'EOF'
stages:
  - test
  - build
  - deploy

python_sanity:
  stage: test
  image: harbor.local/data-platform/platform-python:3.12
  script:
    - python -m compileall dags

kaniko_build:
  stage: build
  image:
    name: harbor.local/data-platform/platform-kaniko-executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - export IMAGE_NAME="harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-airflow"
    - mkdir -p /kaniko/.docker
    - >
      printf '{"auths":{"https://harbor.local":{"username":"%s","password":"%s"}}}'
      "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > /kaniko/.docker/config.json
    - /kaniko/executor --context "${CI_PROJECT_DIR}" --dockerfile "${CI_PROJECT_DIR}/Dockerfile" --destination "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" --destination "${IMAGE_NAME}:latest"

deploy_airflow:
  stage: deploy
  image: harbor.local/data-platform/platform-kubectl:latest
  needs:
    - kaniko_build
  script:
    - export IMAGE_NAME="harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-airflow"
    - export DEPLOY_ENV="${DEPLOY_ENV:-dev}"
    - export DEPLOY_NAMESPACE="data-platform-${DEPLOY_ENV}"
    - echo "$KUBECONFIG_B64" | base64 -d > kubeconfig
    - export KUBECONFIG="${CI_PROJECT_DIR}/kubeconfig"
    - kubectl set image deployment/airflow airflow="${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" -n "${DEPLOY_NAMESPACE}"
    - kubectl rollout status deployment/airflow -n "${DEPLOY_NAMESPACE}" --timeout=180s
EOF
}

write_jupyter_ci() {
  local repo_dir="$1"

  cat > "${repo_dir}/.gitlab-ci.yml" <<'EOF'
stages:
  - build
  - deploy

kaniko_build:
  stage: build
  image:
    name: harbor.local/data-platform/platform-kaniko-executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - export IMAGE_NAME="harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-jupyter"
    - mkdir -p /kaniko/.docker
    - >
      printf '{"auths":{"https://harbor.local":{"username":"%s","password":"%s"}}}'
      "$HARBOR_USERNAME" "$HARBOR_PASSWORD" > /kaniko/.docker/config.json
    - /kaniko/executor --context "${CI_PROJECT_DIR}" --dockerfile "${CI_PROJECT_DIR}/Dockerfile" --destination "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" --destination "${IMAGE_NAME}:latest"

deploy_jupyter:
  stage: deploy
  image: harbor.local/data-platform/platform-kubectl:latest
  needs:
    - kaniko_build
  script:
    - export IMAGE_NAME="harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-jupyter"
    - export DEPLOY_ENV="${DEPLOY_ENV:-dev}"
    - export DEPLOY_NAMESPACE="data-platform-${DEPLOY_ENV}"
    - echo "$KUBECONFIG_B64" | base64 -d > kubeconfig
    - export KUBECONFIG="${CI_PROJECT_DIR}/kubeconfig"
    - kubectl set image deployment/jupyter jupyter="${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" -n "${DEPLOY_NAMESPACE}"
    - kubectl rollout status deployment/jupyter -n "${DEPLOY_NAMESPACE}" --timeout=180s
EOF
}

write_repo_readme() {
  local repo_dir="$1"
  local repo_name="$2"
  local image_name="$3"
  local deployment_name="$4"

  cat > "${repo_dir}/README.md" <<EOF
# ${repo_name}

이 디렉터리는 GitLab 의 개별 app repo 로 push 하는 스캐폴드입니다.

## CI/CD 흐름

- GitLab Runner 가 pipeline 을 실행
- Kaniko 로 Harbor \`data-platform/*\` 이미지 빌드/푸시
- \`kubectl set image\` 로 Kubernetes deployment \`${deployment_name}\` 갱신

## 필요한 GitLab CI 변수

- \`HARBOR_USERNAME\`
- \`HARBOR_PASSWORD\`
- \`NEXUS_PYPI_INDEX_URL\` (backend)
- \`NEXUS_PYPI_TRUSTED_HOST\` (backend)
- \`NEXUS_NPM_REGISTRY\` (frontend)
- \`NEXUS_NPM_AUTH_B64\` (frontend, optional)

브랜치는 \`dev\` 또는 \`prod\`를 사용하면 환경별 namespace/dev-proxy URL이 자동으로 적용됩니다.

## 배포 대상

- Harbor image: \`${image_name}\`
- Kubernetes deployment: \`${deployment_name}\`
EOF
}

write_root_readme() {
  cat > "${OUT_DIR}/README.md" <<'EOF'
# GitLab Repo Export

이 디렉터리는 app 모듈을 GitLab 의 개별 repo 로 분리하기 위한 산출물입니다.

## 생성되는 repo

- `platform-backend`
- `platform-frontend`
- `platform-airflow`
- `platform-jupyter`

현재 작업 중인 루트 repo 는 `platform-infra` 역할을 맡습니다.
EOF
}

export_backend_repo() {
  local repo_dir="${OUT_DIR}/platform-backend"
  copy_app_contents "backend" "${repo_dir}"
  write_repo_gitignore "${repo_dir}"
  write_backend_ci "${repo_dir}"
  write_repo_readme "${repo_dir}" "platform-backend" 'harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-backend' "backend"
}

export_frontend_repo() {
  local repo_dir="${OUT_DIR}/platform-frontend"
  copy_app_contents "frontend" "${repo_dir}"
  write_repo_gitignore "${repo_dir}"
  write_frontend_ci "${repo_dir}"
  write_repo_readme "${repo_dir}" "platform-frontend" 'harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-frontend' "frontend"
}

export_airflow_repo() {
  local repo_dir="${OUT_DIR}/platform-airflow"
  copy_app_contents "airflow" "${repo_dir}"
  write_repo_gitignore "${repo_dir}"
  write_airflow_ci "${repo_dir}"
  write_repo_readme "${repo_dir}" "platform-airflow" 'harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-airflow' "airflow"
}

export_jupyter_repo() {
  local repo_dir="${OUT_DIR}/platform-jupyter"
  copy_app_contents "jupyter" "${repo_dir}"
  write_repo_gitignore "${repo_dir}"
  write_jupyter_ci "${repo_dir}"
  write_repo_readme "${repo_dir}" "platform-jupyter" 'harbor.local/${HARBOR_PROJECT:-data-platform}/k8s-data-platform-jupyter' "jupyter"
}

clean_output_dir
write_root_readme
export_backend_repo
export_frontend_repo
export_airflow_repo
export_jupyter_repo

printf 'Exported GitLab app repos to %s\n' "${OUT_DIR}"
