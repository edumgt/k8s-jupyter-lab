# 기술 스택 역할 정리

이 문서는 이 레포에서 사용하는 각 기술이 Kubernetes 중심 구조에서 어떤 역할을 맡는지 설명합니다.

## 전체 관점

이 레포는 `Ubuntu 24 OVA -> Docker Engine + containerd + kubeadm host -> Kubernetes workload -> Docker Hub/GitHub Actions + Harbor snapshot` 흐름을 하나의 실습 환경으로 만든 구조입니다. 실행과 운영의 기준점은 `kubectl`, `manifest`, `kustomize` 이며, `dev` 와 `prod` 는 overlay로 구분합니다.

## 솔루션별 역할

| 기술 | 이 레포에서 맡는 역할 | 왜 이 솔루션을 썼는가 | 운영 포인트 |
| --- | --- | --- | --- |
| Ubuntu 24 | OVA 베이스 OS, Kubernetes 호스트 런타임 | 최신 LTS 기반으로 containerd, kubeadm, Python 3.12 계열과 잘 맞음 | OVA 빌드 시 ISO/OVF Tool/VMware 경로만 맞추면 됨 |
| Packer | Ubuntu 24 VM 이미지를 반복 가능하게 생성 | VM 구축 과정을 코드화하기 좋음 | [packer/k8s-data-platform.pkr.hcl](../packer/k8s-data-platform.pkr.hcl) 기준 |
| Ansible | OVA 내부에 kubeadm 기반 Kubernetes, 도구 체인, manifest 파일을 배치 | 이미지 내부 구성을 재현 가능하게 유지 | [ansible/playbook.yml](../ansible/playbook.yml) 참조 |
| Kubernetes | 전체 플랫폼의 실제 실행 환경 | 단일 노드로도 pod/service/pvc/NodePort 구조를 실습 가능 | [infra/k8s/base/kustomization.yaml](../infra/k8s/base/kustomization.yaml) + [infra/k8s/overlays/dev/kustomization.yaml](../infra/k8s/overlays/dev/kustomization.yaml) 기준 |
| Docker/OCI image | 앱 이미지를 패키징하는 형식 | Docker Hub mirror, local Docker build, GitHub Actions 배포 경로를 통일하기 좋음 | 런타임은 Docker Compose 가 아니라 Kubernetes deployment |
| Kaniko | Docker daemon 없이 이미지를 build/push 하는 CI 빌더 | Kubernetes executor 와 궁합이 좋고 dind 의존도를 줄임 | 개별 app GitLab repo CI 에서 사용 |
| Python 3.12 | Backend API, Jupyter, Airflow DAG 생태계의 공통 언어 | 데이터/분석/운영 자동화를 한 언어로 다루기 좋음 | FastAPI, Jupyter, Airflow 검증에 재사용 |
| FastAPI | 플랫폼 상태와 데이터 접근을 제공하는 Backend | Python 친화적이고 OpenAPI 제공이 쉬움 | [apps/backend/app/main.py](../apps/backend/app/main.py) |
| Node 22.22 | Quasar 프론트엔드 빌드 체인 | Vue 3 / Vite 생태계에 맞는 안정적인 빌드 환경 | 런타임이 아니라 build stage 버전 고정용 |
| Quasar Framework(Vue 3) | 운영 대시보드형 Frontend | 카드, 배너, 테이블 UI 를 빠르게 구성 가능 | [apps/frontend/src/App.vue](../apps/frontend/src/App.vue) |
| MongoDB | 문서형 메타데이터 저장소 예시 | 작업 정의, 노트북 메타, 비정형 데이터 저장에 적합 | StatefulSet + PVC 로 배포 |
| Redis | 캐시와 빠른 상태 저장소 | health, 세션, 빠른 키-값 저장 흐름을 보여주기 좋음 | 단일 Deployment 로 배포 |
| Apache Airflow | 선택형 스케줄링과 오케스트레이션 | DAG 기반 파이프라인 실습에 적합하지만 현재 핵심 런타임 경로에는 필수는 아님 | [apps/airflow/dags/platform_health_dag.py](../apps/airflow/dags/platform_health_dag.py) |
| JupyterLab | 분석/실험용 워크벤치 pod | 분석가가 cluster 안에서 바로 notebook 을 실행 가능 | Deployment + PVC 로 구성 |
| Teradata SQL(ANSI SQL) | 기업 DW 질의 계층 예시 | 레거시 DW 와 현대 앱/노트북의 접점을 보여주기 위함 | 접속 정보가 없으면 mock 모드 |
| GitLab | 소스 관리와 CI/CD 오케스트레이션 | self-hosted CI 흐름을 k8s 위에서 실습 가능 | GitLab CE 자체도 k8s Deployment 로 배포하고 app source 는 개별 GitLab repo 로 분리 |
| GitLab Runner | GitLab job 실행기 | pipeline job 을 cluster 내부 pod 로 실행 | `k8s executor` 오버레이로 분리하고 app repo 배포를 수행 |
| Nexus Repository | PyPI/npm 폐쇄망 패키지 저장소 | Python + Node 패키지를 한 저장소에서 proxy/group 으로 관리 가능 | `scripts/setup_nexus_offline.sh` 로 repo bootstrap + cache warm-up |
| Harbor | per-user Jupyter snapshot 레지스트리 | 사용자 workspace 를 이미지화해서 다음 로그인에 재사용 가능 | 플랫폼 공통 이미지는 Docker Hub `edumgt/*`, Harbor 는 snapshot 전용 |

## 레이어별 설명

### 1. 이미지/호스트 레이어

- `Ubuntu 24 + Packer + Ansible` 은 kubeadm 기반 Kubernetes 호스트 자체를 재현하는 레이어입니다.
- 이 레이어를 통해 개발 환경 차이보다 Kubernetes 배포 결과에 집중할 수 있습니다.

### 2. 애플리케이션 레이어

- `FastAPI`, `MongoDB`, `Redis`, `Airflow`, `Jupyter`, `Quasar` 가 실제 사용자 워크로드 레이어입니다.
- 모두 Kubernetes manifest 로 배포되며, pod/service/pvc 단위로 관리됩니다.

### 3. 배포/운영 레이어

- `Docker Hub + GitHub Actions + GitLab Runner + Nexus + Harbor snapshot` 이 이미지 빌드와 배포 자동화 레이어입니다.
- Runner 는 Docker executor 대신 Kubernetes executor 기준으로 설계했습니다.
- 이미지 빌드는 `Kaniko` 로 수행해 non-k8s 실행 경로를 줄였습니다.
- 폐쇄망 패키지 캐시는 `Nexus` 가 맡고, Harbor 는 계속 Jupyter snapshot 전용으로 남깁니다.
- 배포 환경은 `infra/k8s/overlays/dev` 와 `infra/k8s/overlays/prod` 로 분기합니다.
- backend 와 frontend 를 하나의 pod 로 묶은 최소 profile 은 `infra/k8s/offline-suite` 에 별도 정의했습니다.
- 오프라인 번들은 image tar 뿐 아니라 `k8s manifests + helper scripts + 운영 문서` 를 함께 묶어 폐쇄망에서도 같은 Kubernetes 적용 흐름을 유지합니다.
- app source 는 `platform-backend`, `platform-frontend`, `platform-airflow`, `platform-jupyter` 같은 개별 GitLab repo 로 분리하는 운영 모델을 기준으로 합니다.

## 실행 스크립트 역할

| 스크립트 | 역할 |
| --- | --- |
| [scripts/apply_k8s.sh](../scripts/apply_k8s.sh) | `--env dev|prod` 기준 플랫폼 overlay 적용 |
| [scripts/reset_k8s.sh](../scripts/reset_k8s.sh) | 선택한 환경의 k8s 리소스 삭제 |
| [scripts/status_k8s.sh](../scripts/status_k8s.sh) | 선택한 환경의 node/pod/service/pvc 상태 확인 |
| [scripts/build_k8s_images.sh](../scripts/build_k8s_images.sh) | Docker Hub mirror + local Kubernetes runtime image import |
| [scripts/publish_dockerhub.sh](../scripts/publish_dockerhub.sh) | 현재 Docker login 기준 Docker Hub push |
| [scripts/prepare_offline_bundle.sh](../scripts/prepare_offline_bundle.sh) | 폐쇄망용 image/wheel/npm cache 와 k8s bundle 자산 준비 |
| [scripts/import_offline_bundle.sh](../scripts/import_offline_bundle.sh) | 폐쇄망 bundle 의 image import 와 k8s overlay apply |
| [scripts/run_wsl.sh](../scripts/run_wsl.sh) | OVA 빌드 자동화 |

## 정리 기준

- runtime/deploy/ops 관점에서 non-k8s 설정은 제거했습니다.
- Docker Compose, 단일 호스트 서비스, 로컬 컨테이너 이름 기반 실행 흐름은 남기지 않았습니다.
- GitLab Runner 는 선택형 k8s 오버레이로, 다시 `dev/prod` overlay로 분리했습니다.
