# TODO (VMware 3-node / OVA 반복 빌드 기준)

## P0 - 매 변경 시 반드시 수행

- [ ] 코드/매니페스트 변경 후 `start.sh`로 3-node 재구성
- [ ] 자동 검증(노드/파드/PVC/배치/Ingress) 통과 확인
- [ ] PC 재기동 후 `scripts/vmware_post_reboot_verify.sh`로 복원/접속/clone 재확인
- [ ] FE/BE/Jupyter/GitLab/Nexus 핵심 시나리오 스모크 테스트
- [ ] `ovabuild.sh`로 OVA 3개 export 및 산출물(sha256) 점검
- [ ] `README.md`, `docs/vmware/README.md`, `CHECKLIST.md` 동기화

## P1 - 오프라인 개발성 강화

- [ ] Python seed 목록 주기 업데이트 (`scripts/offline/python-dev-seed.txt`)
- [ ] npm seed 목록 주기 업데이트 (`scripts/offline/npm-dev-seed.txt`)
- [ ] Nexus warm-up 실패 케이스 재시도 로직/리포트 보강
- [ ] GitLab 프로젝트 seed 자동화 스크립트 고도화

## P1 - 운영 안정성

- [ ] `start.sh` 실패 단계별 재시작 옵션(예: verify-only, export-only) 추가
- [ ] Pod readiness timeout 프로파일(dev/prod) 분리
- [ ] OVA export 후 자동 해시/manifest 파일 생성
- [ ] 배치 검증 결과를 파일(`dist/reports/*.md`)로 저장

## P2 - 문서/협업

- [ ] 다국어 README(EN/JA/ZH)에도 VMware 3-node 최신 흐름 반영
- [ ] 폐쇄망 전달 패키지 표준 폴더 구조 문서화
- [ ] 릴리스 태깅 규칙(예: `ova-YYYYMMDD-N`) 확정

## 이번 사이클 메모

- [ ] 목표 버전:
- [ ] 적용 브랜치:
- [ ] 포함 기능:
- [ ] 제외/보류 기능:
- [ ] 리스크:
- [ ] 완료 기준:
