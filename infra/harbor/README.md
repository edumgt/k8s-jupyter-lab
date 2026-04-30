# Harbor Snapshot Notes

이 저장소에서 Harbor 는 `per-user Jupyter snapshot image` 저장소에 더해, 폐쇄망 기준 플랫폼 공통 이미지와 Kubernetes 부가 이미지를 함께 저장하는 기본 내부 레지스트리 역할을 맡습니다.

## 용도

- 사용자 workspace 를 Kaniko Job 으로 이미지화
- 이미지 경로: `harbor.local/data-platform/jupyter-user-<session-id>:latest`
- 다음 로그인 시 backend 가 최신 restorable snapshot image 를 우선 선택
- 플랫폼 기본 app/runtime 이미지를 `harbor.local/data-platform/*` 에서 pull

## 필요한 설정

- ConfigMap
  - `PLATFORM_HARBOR_URL`
  - `PLATFORM_HARBOR_REGISTRY`
  - `PLATFORM_HARBOR_PROJECT`
  - `PLATFORM_HARBOR_INSECURE_REGISTRY`
- Secret
  - `PLATFORM_HARBOR_USER`
  - `PLATFORM_HARBOR_PASSWORD`

## 운영 메모

- snapshot publish 는 backend 가 Kubernetes Job 을 생성해서 수행합니다.
- restore pull 이 필요하므로 Harbor project 는 public 으로 두거나 별도 imagePullSecret 전략을 준비하세요.
- air-gap 운영 기준 기본 이미지는 `harbor.local/data-platform/*` 로 preload/pull 하도록 맞춥니다.
