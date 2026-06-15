#!/usr/bin/env bash

: "${IMAGE_REGISTRY:=docker.io}"
: "${IMAGE_NAMESPACE:=edumgt}"
: "${IMAGE_TAG:=latest}"

DEFAULT_IMAGE_REGISTRY="docker.io"
DEFAULT_IMAGE_NAMESPACE="edumgt"
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
  local to_prefix
  to_prefix="$(image_registry_prefix)/"

  sed \
    -e "s#harbor\.local/data-platform/#${to_prefix}#g" \
    -e "s#docker\.io/edumgt/#${to_prefix}#g" \
    -e "s#${DEFAULT_IMAGE_REGISTRY}/${DEFAULT_IMAGE_NAMESPACE}/#${to_prefix}#g" \
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

images:
  - name: harbor.local/data-platform/k8s-data-platform-backend
    newName: $(image_registry_prefix)/k8s-data-platform-backend
    newTag: ${IMAGE_TAG}
  - name: harbor.local/data-platform/k8s-data-platform-frontend
    newName: $(image_registry_prefix)/k8s-data-platform-frontend
    newTag: ${IMAGE_TAG}
  - name: harbor.local/data-platform/k8s-data-platform-jupyter
    newName: $(image_registry_prefix)/k8s-data-platform-jupyter
    newTag: ${IMAGE_TAG}
  - name: edumgt/k8s-data-platform-backend
    newName: $(image_registry_prefix)/k8s-data-platform-backend
    newTag: ${IMAGE_TAG}
  - name: edumgt/k8s-data-platform-frontend
    newName: $(image_registry_prefix)/k8s-data-platform-frontend
    newTag: ${IMAGE_TAG}
  - name: edumgt/k8s-data-platform-jupyter
    newName: $(image_registry_prefix)/k8s-data-platform-jupyter
    newTag: ${IMAGE_TAG}
EOF
}
