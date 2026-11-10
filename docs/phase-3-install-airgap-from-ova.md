# Phase 3: 완성 OVA 폐쇄망 설치

목표: 완성된 OVA와 오프라인 번들로 폐쇄망 환경에 설치합니다.

## 로컬 리허설

OVA 반입 전에 같은 포트의 로컬 데모가 필요하면:

```bash
bash scripts/quickstart_airgap_mock.sh
```

Harbor/GitLab/Nexus/Airflow는 mock입니다. 폐쇄망 설치는 아래 `full` 경로를 사용합니다.

## 실행

```bash
bash scripts/phase3_install_from_completed_ova.sh full
```

## 단계별 실행

```bash
bash scripts/phase3_install_from_completed_ova.sh import-only --bundle-dir /opt/k8s-data-platform/offline-bundle
bash scripts/phase3_install_from_completed_ova.sh install-only
bash scripts/phase3_install_from_completed_ova.sh check-only
```

## 검증

```bash
kubectl get nodes -o wide
kubectl get pods -A
bash scripts/check_vm_airgap_status.sh
```
