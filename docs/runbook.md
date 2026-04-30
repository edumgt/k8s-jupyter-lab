# Runbook

## 1. 호스트 상태 확인

```bash
systemctl status docker
systemctl status containerd
systemctl status kubelet
docker ps
```

## 2. 클러스터 상태 확인

```bash
kubectl get nodes
kubectl get pods -n data-platform-dev
kubectl get svc -n data-platform-dev
kubectl get pvc -n data-platform-dev
```

## 3. 플랫폼 이미지 재준비

```bash
bash scripts/build_k8s_images.sh --namespace edumgt --tag latest
```

Docker Hub push 가 필요하면:

```bash
bash scripts/publish_dockerhub.sh --namespace edumgt --tag latest
```

## 4. 플랫폼 적용

```bash
bash scripts/apply_k8s.sh --env dev
bash scripts/apply_k8s.sh --env prod
```

## 5. 플랫폼 초기화

```bash
bash scripts/reset_k8s.sh --env dev
bash scripts/reset_k8s.sh --env prod
```

## 6. 사용자별 Jupyter snapshot 확인

```bash
curl -sS http://localhost:30081/api/jupyter/snapshots/student01 | jq
```

snapshot publish:

```bash
curl -sS http://localhost:30081/api/jupyter/snapshots \
  -H 'Content-Type: application/json' \
  -d '{"username":"student01"}' | jq
```

## 7. 주요 복구 예시

```bash
sudo systemctl restart docker
sudo systemctl restart containerd
sudo systemctl restart kubelet
kubectl rollout restart deployment/backend -n data-platform-dev
kubectl rollout restart deployment/frontend -n data-platform-dev
kubectl rollout restart deployment/jupyter -n data-platform-dev
kubectl rollout restart deployment/airflow -n data-platform-dev
kubectl rollout restart deployment/gitlab -n data-platform-dev
```

## 8. kubelet(:10250) / 이미지 Pull DNS 타임아웃 복구

```bash
sudo bash scripts/fix_kubelet_network_timeouts.sh --dns-servers 192.168.56.1,1.1.1.1,8.8.8.8
```

이 스크립트는 아래를 한 번에 보정합니다.

- UFW kubelet/kube-proxy 포트 허용 (`10250/tcp`, `10256/tcp`)
- `systemd-resolved` DNS 고정
- kubelet `--resolv-conf` 고정 및 서비스 재시작
- kubelet 포트 리스닝 여부와 DNS 해석 probe

## 9. Runner 활성화

```bash
bash scripts/apply_k8s.sh --env dev --with-runner
kubectl scale deployment/gitlab-runner -n data-platform-dev --replicas=1
```

## 10. 폐쇄망 번들 재생성

```bash
bash scripts/prepare_offline_bundle.sh --out-dir dist/offline-bundle
```

오프라인 번들에서 이미지 import 와 Kubernetes 적용까지 함께 진행하려면:

```bash
bash scripts/import_offline_bundle.sh --bundle-dir dist/offline-bundle --apply --env dev
```

Nexus 기반 패키지 저장소까지 같이 준비하려면:

```bash
bash scripts/setup_nexus_offline.sh --namespace data-platform-dev --nexus-url http://127.0.0.1:30091
```

backend 와 frontend 를 하나의 pod 로 묶은 최소 폐쇄망 profile:

```bash
bash scripts/apply_offline_suite.sh
```

OVA 내부 기본 경로:

```bash
ls -lah /opt/k8s-data-platform/offline-bundle
ls -lah /opt/k8s-data-platform/offline-bundle/k8s
```
