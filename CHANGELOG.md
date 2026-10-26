# CHANGELOG.md

## 2026-10-26

- 루트 `README.md`를 영문으로 전환하고, 한글 원문은 `readme-kr.md`로 보존
- `docs/i18n/README.{en,ja,zh}.md` 언어 링크를 루트 영문/한글 README에 맞게 수정

## 2026-07-03

- 루트 `.md` 문서 정리 (`DOCS_MAP.md` 제안 반영)
  - `TEST*.md` → `docs/archive/`로 이동
  - 테스트 스냅샷 영/일/중 번역을 전문 번역 대신 한국어 원문 링크로 축소
  - `README.en/ja/zh.md`를 vmware-k8s-jupyter 병합 이후의 `README.md` 내용에 맞게 재번역

## 2026-04-17

- 저장소를 VM/OVA/air-gap 중심으로 재편
- `apps/`, `applications/`, app 배포 전용 매니페스트/문서/스크립트 제거
- 단계 스크립트 재구성
  - `scripts/phase1_build_ova_assets.sh`
  - `scripts/phase2_operate_airgap_cluster.sh`
  - `scripts/phase3_install_from_completed_ova.sh`
  - `scripts/import_offline_bundle.sh`
- 루트/단계 문서 전면 정리
  - `README*`, `QUICKSTART.md`, `DOCS_MAP.md`, `INSTALL.md`, `TROUBLESHOOTING.md`
  - `docs/phase-1/2/3`, `docs/vmware/README.md`
