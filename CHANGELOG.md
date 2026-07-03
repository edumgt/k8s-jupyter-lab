# CHANGELOG.md

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
