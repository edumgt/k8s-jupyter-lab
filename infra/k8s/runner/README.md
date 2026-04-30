# GitLab Runner Overlay

이 오버레이는 GitLab Runner 를 `kubernetes executor` 기준으로 배포합니다.
Runner 는 `platform-backend`, `platform-frontend`, `platform-airflow`, `platform-jupyter` 같은 개별 app GitLab repo 의 pipeline 을 실행하고, 각 repo 가 자기 deployment 를 직접 갱신하는 구조를 전제로 합니다.

## 적용 순서

1. dev 또는 prod 환경에 맞는 예시 secret 파일을 선택합니다.

- dev: [secret.example.yaml](base/secret.example.yaml) 내용을 기준으로 [secret.example-patch.yaml](overlays/dev/secret.example-patch.yaml) 의 `token` 값을 변경
- prod: [secret.example.yaml](base/secret.example.yaml) 내용을 기준으로 [secret.example-patch.yaml](overlays/prod/secret.example-patch.yaml) 의 `token` 값을 변경

2. 다음 명령으로 오버레이를 적용합니다.

```bash
bash scripts/apply_k8s.sh --env dev --with-runner
kubectl scale deployment/gitlab-runner -n data-platform-dev --replicas=1
```

## 메모

- 기본 `replicas` 는 `0` 입니다.
- 토큰 반영 전에는 scale 하지 않는 것을 권장합니다.
- Runner overlay 는 `data-platform-dev` 또는 `data-platform-prod` namespace에 맞춰 따로 적용합니다.
- app repo split 흐름은 [gitlab-repo-layout.md](../../../docs/gitlab-repo-layout.md) 를 참고하면 됩니다.
