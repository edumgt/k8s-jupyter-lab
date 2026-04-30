# Phase 2: OVA 내부 솔루션 작업 문서

## 목적

OVA로 부팅된 3노드 환경(control-plane + worker 2)에서 솔루션 배포/보정/점검을 수행합니다.

- 오프라인 번들 import + Kubernetes apply
- air-gap 점검
- Harbor 이미지 누락 보충(필요 시)

이 단계는 주로 **control-plane VM 내부**에서 실행합니다.

## 사용 스크립트 (2단계 전용 진입점)

- `scripts/phase2_operate_airgap_cluster.sh`

내부적으로 호출되는 기존 스크립트:

- `scripts/import_offline_bundle.sh`
- `scripts/check_offline_readiness.sh`
- `scripts/status_k8s.sh`
- `scripts/check_harbor_stack_images.sh`
- `scripts/fill_missing_harbor_images_from_bundle.sh` (fill 모드)

## 기본 실행

오프라인 번들 import + apply + 점검:

```bash
bash scripts/phase2_operate_airgap_cluster.sh all \
  --env dev \
  --bundle-dir /opt/k8s-data-platform/offline-bundle
```

## 상황별 실행

이미지 import/apply만 수행:

```bash
bash scripts/phase2_operate_airgap_cluster.sh import-and-apply \
  --env dev \
  --bundle-dir /opt/k8s-data-platform/offline-bundle
```

점검만 수행:

```bash
bash scripts/phase2_operate_airgap_cluster.sh check \
  --env dev \
  --nodes 192.168.56.10,192.168.56.11,192.168.56.12
```

노드 런타임 이미지 누락 보충:

```bash
bash scripts/phase2_operate_airgap_cluster.sh fill-images \
  --bundle-dir /opt/k8s-data-platform/offline-bundle \
  --nodes 192.168.56.10,192.168.56.11,192.168.56.12
```

