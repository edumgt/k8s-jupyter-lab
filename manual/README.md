# 고객사 납품 문서

본 폴더는 고객사 전달용 운영 문서 세트입니다.

## 문서 목록

1. [01_INSTALLATION_MANUAL.md](01_INSTALLATION_MANUAL.md)
   - 설치 준비, 설치 절차, 검증 절차
2. [02_TROUBLESHOOTING_GUIDE.md](02_TROUBLESHOOTING_GUIDE.md)
   - 장애 유형별 점검/복구 가이드
3. [03_USER_OPERATIONS_GUIDE.md](03_USER_OPERATIONS_GUIDE.md)
   - 일상 운영 절차, 서비스 사용, 점검 체크리스트

## 적용 기준

- 저장소 기준: `k8s-data-platform-ova`
- 기본 운영 프로파일: `dev-3node` (control-plane 1 + worker 2)
- 기본 접근 방식: `Ingress(hosts 기반) + 내부 Harbor 이미지 + 오프라인 번들`

## 운영 전 공통 권장사항

1. 기본 계정 비밀번호를 반드시 변경합니다.
2. Windows/WSL/VM hosts 값이 동일하게 적용되어야 합니다.
3. `scripts/check_offline_readiness.sh`로 오프라인 준비 상태를 점검합니다.

