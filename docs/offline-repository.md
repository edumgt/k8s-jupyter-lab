# Offline Artifact Repository

현재 운영 원칙은 아래와 같습니다.

- VM 내부 런타임(Kubernetes 배포/실행)은 `harbor.local/data-platform/*` 만 사용
- 외부망에서의 수집/빌드 결과물은 `offline bundle` 또는 `tar` 로 반입
- 반입한 이미지는 VM의 runtime/containerd 에 import 하여 Harbor 기준 태그로 사용

즉, VM 내부 워크로드 경로에서 `docker.io` 를 직접 참조하지 않는 것이 기본입니다.

## Airflow 역할

- Airflow 는 현재 핵심 런타임 의존성이 아니라 `platform_health_check` DAG 로 backend, frontend, jupyter 상태를 주기적으로 확인하는 샘플 오케스트레이터입니다.
- Jupyter sandbox, GitLab repo 분리, offline bundle, snapshot/restore 경로는 Airflow 없이도 동작합니다.
- 폐쇄망 최소 구성에서는 Airflow 를 빼고 backend + frontend one-pod profile 을 먼저 올리는 쪽이 더 단순합니다.

## 추천 저장소

이 레포는 `Python 3.12` 패키지와 `npm` 패키지를 모두 다뤄야 하므로 `devpi` 단독보다 `Nexus Repository` 가 더 잘 맞습니다.

- PyPI proxy/group 으로 backend, jupyter, airflow wheel warm-up 가능
- npm proxy/group 으로 frontend build cache warm-up 가능
- raw hosted repository 로 offline bundle 자체를 함께 적재 가능
- Harbor 는 플랫폼 기본/runtime 이미지 + snapshot 이미지를 함께 관리 가능

공식 문서:

- Sonatype Nexus Repository formats: https://help.sonatype.com/en/repository-formats.html
- PyPI repositories in Nexus: https://help.sonatype.com/en/pypi-repositories.html
- npm repositories in Nexus: https://help.sonatype.com/en/npm-repositories.html
- Nexus Docker image: https://hub.docker.com/r/sonatype/nexus3

## 설치 순서

기본 stack 에는 `infra/k8s/base/nexus.yaml` 이 포함되어 있습니다.

```bash
bash scripts/apply_k8s.sh --env dev
bash scripts/setup_nexus_offline.sh --namespace data-platform-dev --nexus-url http://nexus.platform.local
```

참고:
- control-plane VM 내부에서 직접 실행할 때는 `--nexus-url http://127.0.0.1:30091` 를 사용해도 됩니다.

Nexus 가 이미 초기화되어 admin 비밀번호가 바뀐 경우:

```bash
bash scripts/setup_nexus_offline.sh \
  --namespace data-platform-dev \
  --nexus-url http://nexus.platform.local \
  --current-password '<current-admin-password>' \
  --target-password '<new-admin-password>' \
  --username admin \
  --password '<new-admin-password>'
```

개발용 추가 seed 라이브러리(Backend Python + Vue3/Quasar npm)를 함께 워밍하려면:

```bash
bash scripts/setup_nexus_offline.sh \
  --namespace data-platform-dev \
  --nexus-url http://nexus.platform.local \
  --username admin \
  --password '<nexus-password>' \
  --python-seed-file scripts/offline/python-dev-seed.txt \
  --npm-seed-file scripts/offline/npm-dev-seed.txt
```

생성되는 주요 endpoint:

- `http://nexus.platform.local/repository/pypi-all/simple`
- `http://nexus.platform.local/repository/npm-all/`
- `http://nexus.platform.local/repository/offline-bundle/`

## 권장 PVC 용량 (폐쇄망 개발 기준)

- `nexus-data`: `80Gi`
- `gitlab-data`: `60Gi`
- `gitlab-config`: `10Gi`
- `gitlab-logs`: `10Gi`
- `jupyter-workspace`: `10Gi`

재부팅 후 의존성 접근 검증:

```bash
bash scripts/verify_nexus_dependencies.sh \
  --nexus-url http://nexus.platform.local \
  --username admin \
  --password '<nexus-password>'
```

## 폐쇄망 one-pod app profile

backend 와 frontend 를 하나의 pod 로 묶은 최소 profile 은 별도 kustomization 으로 제공합니다.

```bash
bash scripts/apply_offline_suite.sh
```

주요 포트:

- frontend: `31080`
- backend: `31081`
- jupyter: `31088`
- nexus: `31091`

이 profile 은 `Airflow` 를 의도적으로 제외하고, `MongoDB + Redis + Jupyter PVC + Nexus` 만 함께 올립니다.
