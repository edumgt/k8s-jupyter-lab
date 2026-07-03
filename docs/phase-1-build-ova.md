# Phase 1: OVA 빌드

목표: 인터넷 연결 환경에서 VM 이미지와 OVA 산출물을 준비합니다.

## 실행

```bash
bash scripts/phase1_build_ova_assets.sh all
```

## 개별 실행

```bash
bash scripts/phase1_build_ova_assets.sh bundle-only
bash scripts/phase1_build_ova_assets.sh ova-only --dist-dir C:/ffmpeg
```

## 결과물

- OVA 파일
- 오프라인 번들(이미지 tar + 매니페스트)
- 빌드 로그
