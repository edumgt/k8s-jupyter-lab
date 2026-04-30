# 트러블슈팅 가이드 (고객사 납품용)

## 1. 공통 진단 순서

아래 순서로 점검하면 대부분의 장애를 빠르게 분리할 수 있습니다.

1. 노드 상태 확인
2. 네임스페이스 Pod 상태 확인
3. Ingress/Service/Endpoint 확인
4. 로그 확인
5. 재배포 또는 서비스 재시작

기본 명령:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -n data-platform-dev
kubectl get ingress -n data-platform-dev
```

## 2. 증상별 대응

## 2.1 URL 접속 실패 (`platform.local`, `gitlab.platform.local` 등)

원인 후보:

1. hosts 미등록/오등록
2. ingress-nginx 미기동
3. MetalLB IP 미할당

점검:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide
kubectl get ingress -A
```

조치:

1. hosts 파일 재적용
2. ingress-nginx controller 재시작
3. `scripts/setup_ingress_metallb.sh` 재실행

## 2.2 Pod `ImagePullBackOff` / `ErrImagePull`

원인 후보:

1. `harbor.local` 이미지 미적재
2. registry DNS/hosts 문제
3. 오프라인 번들 미반입

점검:

```bash
kubectl get pods -A | egrep 'ImagePullBackOff|ErrImagePull'
bash scripts/check_offline_readiness.sh
```

조치:

1. 오프라인 번들 import:
```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --apply --env dev
```
2. 부족 이미지 보강:
```bash
bash scripts/fill_missing_harbor_images_from_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle
```

## 2.3 Node `NotReady`

점검:

```bash
kubectl get nodes -o wide
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 200 --no-pager
```

조치:

```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

필요 시 네트워크 보정:

```bash
sudo bash scripts/fix_kubelet_network_timeouts.sh --dns-servers 192.168.56.1,1.1.1.1,8.8.8.8
```

## 2.4 Dashboard 로그인 불가

증상:

`http://dashboard.platform.local`에서 토큰 로그인 버튼 비활성화

원인:

Kubernetes Dashboard 정책상 HTTP(non-localhost)에서 토큰 로그인 제한

현재 구성:

1. `Skip` 로그인 허용
2. Dashboard 서비스 계정은 `dashboard-admin`으로 실행

점검:

```bash
kubectl -n kubernetes-dashboard get deploy kubernetes-dashboard -o jsonpath='{.spec.template.spec.serviceAccountName} {.spec.template.spec.containers[0].args}'
```

## 2.5 Airflow/GitLab/Nexus 개별 장애

점검:

```bash
kubectl -n data-platform-dev get pods -l app=airflow -o wide
kubectl -n data-platform-dev get pods -l app=gitlab -o wide
kubectl -n data-platform-dev get pods -l app=nexus -o wide
kubectl -n data-platform-dev logs deploy/airflow --tail=200
kubectl -n data-platform-dev logs deploy/gitlab --tail=200
kubectl -n data-platform-dev logs deploy/nexus --tail=200
```

## 3. 재배포/복구 절차

## 3.1 롤링 재시작

```bash
kubectl rollout restart deployment/backend -n data-platform-dev
kubectl rollout restart deployment/frontend -n data-platform-dev
kubectl rollout restart deployment/jupyter -n data-platform-dev
kubectl rollout restart deployment/airflow -n data-platform-dev
kubectl rollout restart deployment/gitlab -n data-platform-dev
kubectl rollout restart deployment/nexus -n data-platform-dev
```

## 3.2 전체 재적용

```bash
bash scripts/apply_k8s.sh --env dev --overlay dev-3node
```

## 3.3 백업/복구

```bash
bash scripts/backup_platform.sh --env dev
bash scripts/restore_platform.sh --env dev --backup-dir <backup-dir>
```

## 4. 장애 수집 템플릿

장애 접수 시 아래 정보를 함께 수집하십시오.

1. 발생 시각
2. 영향 서비스(URL)
3. `kubectl get pods -A -o wide`
4. 장애 pod `describe`/`logs`
5. 최근 변경 작업(배포, 설정 변경, 재부팅)

