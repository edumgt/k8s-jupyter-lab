# Phase 2: OVA 내부 운영

목표: OVA로 기동한 VM에서 air-gap 운영 준비를 마무리합니다.

## 실행

```bash
bash scripts/phase2_operate_airgap_cluster.sh all
```

## 점검

```bash
bash scripts/status_k8s.sh
bash scripts/check_vm_airgap_status.sh
```

## 참고

오프라인 번들 재반입이 필요하면:

```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --apply
```
