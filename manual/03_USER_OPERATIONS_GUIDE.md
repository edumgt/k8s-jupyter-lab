# 사용자 운영 가이드 (고객사 납품용)

## 1. 목적

본 문서는 설치 완료 후 운영 담당자/서비스 관리자 관점의 일상 운영 절차를 정의합니다.

## 2. 운영자 기본 루틴

## 2.1 일일 시작 점검

```bash
kubectl get nodes
kubectl get pods -A
bash scripts/verify.sh --http-mode ingress --lb-ip 192.168.56.240
```

확인 기준:

1. 노드 3대 `Ready`
2. 핵심 Pod `Running`
3. Ingress URL 응답 정상

## 2.2 일일 종료 전 점검

1. 에러 Pod 유무 확인
2. 디스크 사용량 확인(`df -h`)
3. 중요 로그/이벤트 확인
4. 백업 정책 수행 여부 확인

## 3. 서비스 접근 정보

## 3.1 주요 URL

1. Frontend: `http://platform.local`
2. Backend Docs: `http://platform.local/docs`
3. Jupyter: `http://jupyter.platform.local/lab`
4. GitLab: `http://gitlab.platform.local`
5. Airflow: `http://airflow.platform.local`
6. Nexus: `http://nexus.platform.local`
7. Dashboard: `http://dashboard.platform.local`

## 3.2 기본 관리자 계정

1. Platform: `admin@test.com / 123456`
2. GitLab: `root / v7Q#2mL!9xC@4pR%8tZ`
3. Airflow: `admin / admin12345!`
4. Nexus: `admin / nexus123!`

운영 전 필수:

1. 모든 기본 비밀번호 변경
2. 변경 이력/보관 정책 수립

## 4. 운영 작업 가이드

## 4.1 플랫폼 배포/재배포

```bash
bash scripts/apply_k8s.sh --env dev --overlay dev-3node
```

## 4.2 상태 조회

```bash
bash scripts/status_k8s.sh --env dev
kubectl get pods -n data-platform-dev -o wide
kubectl get svc -n data-platform-dev
```

## 4.3 정지/기동

```bash
bash scripts/svc-down.sh --env dev
bash scripts/svc-up.sh --env dev
```

## 4.4 오프라인 번들 반입

```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --apply --env dev
```

## 4.5 오프라인 준비 상태 점검

```bash
bash scripts/check_offline_readiness.sh
```

## 5. 대시보드 운영 참고

현재 구성은 HTTP 환경 제약으로 `Skip` 기반 접근을 허용합니다.

1. Dashboard `Skip` 접근 가능
2. `Nodes`, `Pods` 조회 가능하도록 `dashboard-admin` 서비스계정 적용
3. 보안 강화가 필요한 경우 HTTPS + 토큰 로그인 체계로 전환 권장

## 6. 백업/복구 운영

## 6.1 정기 백업

```bash
bash scripts/backup_platform.sh --env dev
```

## 6.2 장애 복구

```bash
bash scripts/restore_platform.sh --env dev --backup-dir <backup-dir>
```

## 7. 월간 점검 체크리스트

1. 외부 registry 참조 이미지가 없는지 확인
2. PVC 사용량 임계치 점검
3. GitLab/Nexus/Airflow 로그인 점검
4. 비밀번호/토큰 정책 준수 점검
5. 샘플 사용자 시나리오(로그인, Jupyter 실행, snapshot) 점검

## 8. 변경관리 권장

1. 운영 반영 전 `dev` 검증 후 `prod` 반영
2. 반영 전/후 `verify.sh` 결과 보관
3. 장애 발생 시 변경 이력 기준 롤백 계획 확보

