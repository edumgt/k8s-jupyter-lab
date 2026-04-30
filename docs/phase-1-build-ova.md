# Phase 1: 최초 OVA 생성용 문서

## 목적

인터넷 가능(online) 빌드 환경에서 다음 산출물을 생성합니다.

- 오프라인 번들 디렉토리 (`dist/offline-bundle`)
- VMware용 OVA 3종 (`k8s-data-platform.ova`, `k8s-worker-1.ova`, `k8s-worker-2.ova`)

이 단계는 "배포 대상 PC"가 아니라 "OVA 제작 PC/WSL"에서 수행합니다.

## 사용 스크립트 (1단계 전용 진입점)

- `scripts/phase1_build_ova_assets.sh`

내부적으로 호출되는 기존 스크립트:

- `scripts/prepare_offline_bundle.sh`
- `scripts/build_vmware_ova_and_verify.sh`

## 기본 실행

```bash
bash scripts/phase1_build_ova_assets.sh all \
  --bundle-out-dir dist/offline-bundle \
  --dist-dir C:/ffmpeg
```

## 부분 실행

오프라인 번들만 만들기:

```bash
bash scripts/phase1_build_ova_assets.sh bundle-only \
  --bundle-out-dir dist/offline-bundle
```

OVA만 다시 생성/검증:

```bash
bash scripts/phase1_build_ova_assets.sh ova-only \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --dist-dir C:/ffmpeg \
  --force
```

## 산출물 전달 규칙

Phase 3 대상 PC로 전달할 최소 파일:

- `k8s-data-platform.ova`
- `k8s-worker-1.ova`
- `k8s-worker-2.ova`
- 저장소의 `init.sh` + `scripts/phase3_install_from_completed_ova.sh`

