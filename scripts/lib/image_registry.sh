#!/usr/bin/env bash

: "${IMAGE_REGISTRY:=harbor.local}"
: "${IMAGE_NAMESPACE:=data-platform}"
: "${IMAGE_TAG:=latest}"

DEFAULT_IMAGE_REGISTRY="harbor.local"
DEFAULT_IMAGE_NAMESPACE="data-platform"
DEFAULT_IMAGE_TAG="latest"

trim_trailing_slashes() {
  local value="${1:-}"
  while [[ "${value}" == */ ]]; do
    value="${value%/}"
  done
  printf '%s' "${value}"
}

image_registry_prefix() {
  local registry namespace
  registry="$(trim_trailing_slashes "${IMAGE_REGISTRY}")"
  namespace="${IMAGE_NAMESPACE#/}"
  namespace="${namespace%/}"
  printf '%s/%s' "${registry}" "${namespace}"
}

platform_app_image() {
  local image_name="$1"
  local image_tag="${2:-${IMAGE_TAG}}"
  printf '%s/k8s-data-platform-%s:%s' "$(image_registry_prefix)" "${image_name}" "${image_tag}"
}

platform_support_image() {
  local image_name="$1"
  local image_tag="$2"
  printf '%s/%s:%s' "$(image_registry_prefix)" "${image_name}" "${image_tag}"
}

registry_override_enabled() {
  [[ "$(trim_trailing_slashes "${IMAGE_REGISTRY}")" != "${DEFAULT_IMAGE_REGISTRY}" ]] \
    || [[ "${IMAGE_NAMESPACE}" != "${DEFAULT_IMAGE_NAMESPACE}" ]] \
    || [[ "${IMAGE_TAG}" != "${DEFAULT_IMAGE_TAG}" ]]
}

rewrite_registry_prefix_in_file() {
  local source_file="$1"
  local target_file="$2"
  local default_prefix="${DEFAULT_IMAGE_REGISTRY}/${DEFAULT_IMAGE_NAMESPACE}/"
  local legacy_prefix="docker.io/edumgt/"
  local to_prefix

  to_prefix="$(image_registry_prefix)/"
  sed \
    -e "s#${default_prefix}#${to_prefix}#g" \
    -e "s#${legacy_prefix}#${to_prefix}#g" \
    "${source_file}" > "${target_file}"
}

write_platform_image_override_kustomization() {
  local target_file="$1"
  local base_resource="$2"

  cat > "${target_file}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ${base_resource}

configMapGenerator:
  - name: platform-config
    behavior: merge
    literals:
      - PLATFORM_JUPYTER_IMAGE=$(platform_app_image jupyter)
      - PLATFORM_JUPYTER_SNAPSHOT_BUILDER_IMAGE=$(platform_support_image platform-kaniko-executor v1.23.2-debug)

images:
  - name: harbor.local/data-platform/k8s-data-platform-backend
    newName: $(image_registry_prefix)/k8s-data-platform-backend
    newTag: ${IMAGE_TAG}
  - name: harbor.local/data-platform/k8s-data-platform-frontend
    newName: $(image_registry_prefix)/k8s-data-platform-frontend
    newTag: ${IMAGE_TAG}
  - name: harbor.local/data-platform/k8s-data-platform-airflow
    newName: $(image_registry_prefix)/k8s-data-platform-airflow
    newTag: ${IMAGE_TAG}
  - name: harbor.local/data-platform/k8s-data-platform-jupyter
    newName: $(image_registry_prefix)/k8s-data-platform-jupyter
    newTag: ${IMAGE_TAG}
  - name: harbor.local/data-platform/platform-mongodb
    newName: $(image_registry_prefix)/platform-mongodb
    newTag: "7.0"
  - name: harbor.local/data-platform/platform-redis
    newName: $(image_registry_prefix)/platform-redis
    newTag: "7-alpine"
  - name: harbor.local/data-platform/platform-gitlab-ce
    newName: $(image_registry_prefix)/platform-gitlab-ce
    newTag: "17.10.0-ce.0"
  - name: harbor.local/data-platform/platform-nexus3
    newName: $(image_registry_prefix)/platform-nexus3
    newTag: "3.90.1-alpine"
  - name: harbor.local/data-platform/platform-kaniko-executor
    newName: $(image_registry_prefix)/platform-kaniko-executor
    newTag: "v1.23.2-debug"
  - name: harbor.local/data-platform/platform-gitlab-runner
    newName: $(image_registry_prefix)/platform-gitlab-runner
    newTag: "alpine-v17.10.0"
  - name: harbor.local/data-platform/platform-gitlab-runner-helper
    newName: $(image_registry_prefix)/platform-gitlab-runner-helper
    newTag: "x86_64-v17.10.0"
  - name: harbor.local/data-platform/platform-alpine
    newName: $(image_registry_prefix)/platform-alpine
    newTag: "3.20"
  - name: harbor.local/data-platform/platform-bash
    newName: $(image_registry_prefix)/platform-bash
    newTag: "5.2"
  - name: harbor.local/data-platform/platform-kubectl
    newName: $(image_registry_prefix)/platform-kubectl
    newTag: "latest"
EOF
}
