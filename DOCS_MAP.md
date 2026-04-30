# DOCS_MAP.md
## 루트 Markdown 문서 정리

이 문서는 루트 폴더의 `.md` 문서가 많아졌을 때, 어떤 문서를 먼저 보고 어떤 상황에서 참고해야 하는지 빠르게 판단하기 위한 인덱스입니다.

## 1) 권장 읽기 순서 (VMware 멀티노드 기준)

1. `README.md`
2. `docs/phase-1-build-ova.md`
3. `docs/phase-2-ova-solution-ops.md`
4. `docs/phase-3-install-airgap-from-ova.md`
5. `docs/vmware/README.md`
6. `QUICKSTART.md`
7. `INSTALL.md`
8. `PORTS.md`
9. `TROUBLESHOOTING.md`
10. `CHECK.md`
11. `CHECKLIST.md`
12. `TODO.md`
13. `CHANGELOG.md`

## 2) 루트 `.md` 파일 목적 요약

| 파일 | 목적 | 언제 보는지 | 비고 |
|---|---|---|---|
| `README.md` | 저장소 전체 설명 + VMware/폐쇄망/운영 흐름 | 처음 시작할 때 | 한국어 메인 엔트리 |
| `README.en.md` | 영문 메인 설명 | 다국어 공유 시 | `README.md`의 영어판 |
| `README.ja.md` | 일본어 메인 설명 | 다국어 공유 시 | `README.md`의 일본어판 |
| `README.zh.md` | 중국어 메인 설명 | 다국어 공유 시 | `README.md`의 중국어판 |
| `QUICKSTART.md` | 최소 명령으로 빠른 기동/확인 | 로컬 빠른 점검 | 짧은 실행 흐름 |
| `INSTALL.md` | 설치/초기 구성 절차 | 신규 VM/OVA 세팅 | 운영자 설치 기준 |
| `PORTS.md` | 포트 맵 | 방화벽/접속 문제 확인 | NodePort/내부포트 정리 |
| `TROUBLESHOOTING.md` | 장애 대응 절차 | Pod/CNI/접속 장애 시 | 빠른 점검 명령 모음 |
| `CHECK.md` | OVA Golden Image 체크리스트 | 배포 전 품질 점검 | 항목형 검수 문서 |
| `CHECKLIST.md` | `start.sh` 반복 빌드/검증 체크리스트 | 변경 후 OVA 재생성 루틴 | VMware 3-node 기준 |
| `TODO.md` | 반복 빌드 고도화 작업 백로그 | 다음 개선 과제 관리 | 우선순위별 TODO 템플릿 |
| `CHANGELOG.md` | 문서/스크립트 변경 이력 | 변경 추적 시 | 최신 변경 요약 |
| `TEST.md` | 테스트 스냅샷(한국어) | 과거 검증 근거 확인 | 2026-03-19 기준, VirtualBox 맥락 포함 |
| `TEST.en.md` | 테스트 스냅샷(영문) | 과거 검증 근거 확인 | `TEST.md` 영어판 |
| `TEST.ja.md` | 테스트 스냅샷(일본어) | 과거 검증 근거 확인 | `TEST.md` 일본어판 |
| `TEST.zh.md` | 테스트 스냅샷(중국어) | 과거 검증 근거 확인 | `TEST.md` 중국어판 |

## 3) 현재 기준 핵심 실행 문서

- VMware 멀티노드 자동 구성: `README.md` + `docs/vmware/README.md`
- 스크립트 역할 분리: `start.sh`(구성/검증), `ovabuild.sh`(OVA export)
- 단일 서비스 빠른 확인: `QUICKSTART.md`
- 설치/운영 표준화: `INSTALL.md`, `CHECK.md`, `CHECKLIST.md`, `TODO.md`, `TROUBLESHOOTING.md`

## 3-1) 3단계 표준 분류 (요청 반영)

문서 3종:

1. `docs/phase-1-build-ova.md` (최초 OVA 생성)
2. `docs/phase-2-ova-solution-ops.md` (OVA 내부 솔루션 작업)
3. `docs/phase-3-install-airgap-from-ova.md` (완성 OVA 복사/설치)

스크립트 3종:

1. `scripts/phase1_build_ova_assets.sh`
2. `scripts/phase2_operate_airgap_cluster.sh`
3. `scripts/phase3_install_from_completed_ova.sh`

## 4) 보조 문서(루트 외) 추천

- `docs/vmware/README.md`: VMware 특화 실행/이슈 가이드
- `docs/runbook.md`: 운영 런북
- `docs/sre-checklist.md`: 운영/SRE 체크리스트
- `docs/offline-repository.md`: 오프라인 저장소 운영 관점
- `docs/ova-proof-20260318.md`: OVA 검증 기록

## 5) 정리 제안 (향후)

1. `TEST*.md`를 `docs/archive/`로 이동해 루트 집중도 개선
2. 루트에는 `README/INSTALL/QUICKSTART/TROUBLESHOOTING/PORTS`만 유지
3. 다국어 문서는 유지하되 테스트 스냅샷은 한국어 원문 + 링크 방식으로 축소
