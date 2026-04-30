# GitLab Repo Layout

이 문서는 현재 구조를 GitLab 의 멀티 리포 방식으로 운영할 때 어떤 repo 를 만들고, GitLab Runner 가 어떤 역할을 맡는지 설명합니다.

## 권장 GitLab 프로젝트 구성

- `platform-infra`
  - 현재 작업 중인 이 repo
  - OVA, Ansible, Kubernetes overlay, GitLab Runner overlay, 운영 문서를 관리
- `platform-backend`
  - `apps/backend` 코드
  - 이미지 빌드 후 `deployment/backend` 갱신
- `platform-frontend`
  - `apps/frontend` 코드
  - 이미지 빌드 후 `deployment/frontend` 갱신
- `platform-airflow`
  - `apps/airflow` 코드
  - 이미지 빌드 후 `deployment/airflow` 갱신
- `platform-jupyter`
  - `apps/jupyter` 코드
  - 이미지 빌드 후 `deployment/jupyter` 갱신

## GitLab Runner 역할

- Runner 는 Kubernetes executor 로 `data-platform-dev` 또는 `data-platform-prod` namespace 에 배포
- 각 app repo 의 pipeline 을 실행
- Kaniko 로 Docker Hub `edumgt/*` 이미지를 build/push
- `kubectl set image` 로 대상 deployment 를 갱신

## repo export

현재 repo 에서 app 모듈별 GitLab repo 스캐폴드를 만들려면:

```bash
bash scripts/export_gitlab_repos.sh --force
```

생성 위치 기본값:

- `dist/gitlab-repos/platform-backend`
- `dist/gitlab-repos/platform-frontend`
- `dist/gitlab-repos/platform-airflow`
- `dist/gitlab-repos/platform-jupyter`

각 repo 에는 다음 파일이 들어갑니다.

- app source
- `Dockerfile`
- `.gitlab-ci.yml`
- `README.md`
- `.gitignore`

## app repo pipeline 공통 변수

- `DOCKERHUB_NAMESPACE`
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN`
- `KUBECONFIG_B64`
- `DEPLOY_ENV`

추가로 frontend repo 는 다음 변수를 선택적으로 사용합니다.

- `VITE_API_BASE_URL`

## 배포 순서

1. `platform-infra` repo pipeline 또는 `bash scripts/apply_k8s.sh --env dev --with-runner` 로 infra 와 runner 를 올립니다.
2. app repo 를 GitLab 프로젝트로 push 합니다.
3. 각 app repo 의 GitLab CI/CD 변수에 Docker Hub / kubeconfig 값을 설정합니다.
4. app repo pipeline 이 Runner 위에서 실행되며 개별 app deployment 를 갱신합니다.
