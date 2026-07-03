# CHECK.md
## 폐쇄망 배포용 OVA Golden Image 체크리스트

작성일: 2026-03-20

---

## 1. 기본 OS 및 환경
- [ ] OS 설치 완료 (Ubuntu / Rocky / AlmaLinux 등)
- [ ] 시간대 / locale 설정
- [ ] 필수 패키지 설치 (curl, vim, net-tools 등)
- [ ] qemu-guest-agent 설치
- [ ] 불필요 패키지 제거

---

## 2. 보안 설정
- [ ] 기본 계정/비밀번호 정책 적용
- [ ] root SSH 접근 제한
- [ ] sudo 정책 설정
- [ ] 방화벽 기본 정책 설정
- [ ] SSH key 기반 로그인 구성

---

## 3. 네트워크
- [ ] DHCP 정상 동작 확인
- [ ] 정적 IP 설정 스크립트 제공
- [ ] hostname 변경 스크립트 제공
- [ ] /etc/hosts fallback 구성
- [ ] DNS 없는 환경에서도 동작 가능

---

## 4. 오프라인 패키지
- [ ] apt / rpm 패키지 오프라인 저장
- [ ] Python wheelhouse 준비
- [ ] Node/npm 캐시 또는 빌드 결과 포함
- [ ] Helm chart 저장
- [x] Kubernetes manifest 포함

---

## 5. 컨테이너 이미지
- [ ] Docker / containerd 설치
- [ ] 필수 이미지 tar 저장 (docker save)
- [ ] ctr 또는 docker load 테스트 완료
- [ ] 내부 registry 사용 여부 결정

---

## 6. 플랫폼 구성
- [ ] Kubernetes (kubeadm 또는 경량 k8s) 설치
- [ ] CNI 포함
- [ ] ingress 구성
- [ ] NodePort 또는 MetalLB 설정
- [ ] CoreDNS 정상 동작

---

## 7. 애플리케이션
- [x] frontend/backend 포함
- [ ] DB schema 및 초기 데이터
- [x] 서비스 기동 스크립트
- [x] health check script

---

## 8. 디렉터리 구조
- [ ] /opt/company/bin
- [ ] /opt/company/config
- [ ] /opt/company/images
- [ ] /opt/company/packages
- [ ] /opt/company/scripts
- [ ] /opt/company/docs

---

## 9. First Boot 처리
- [ ] machine-id 재생성
- [ ] SSH host key 재생성
- [ ] hostname 변경
- [ ] 네트워크 재설정
- [ ] 초기 로그 생성

---

## 10. 로그 및 운영
- [ ] 로그 경로 표준화
- [x] health check 명령 제공
- [x] 서비스 관리 명령 제공 (svc-up/down)
- [x] 백업/복구 스크립트

---

## 11. 문서 포함
- [x] INSTALL.md
- [x] QUICKSTART.md
- [x] TROUBLESHOOTING.md
- [x] PORTS.md
- [x] CHANGELOG.md

---

## 12. 이미지 정리
- [ ] 캐시 제거
- [ ] 로그 초기화
- [ ] cloud-init 제거
- [ ] 불필요 파일 삭제

---

## 13. 배포 준비
- [ ] OVA export 완료
- [ ] qcow2 변환 테스트
- [ ] VM 부팅 테스트
- [ ] 폐쇄망 환경 테스트 완료

---

## ✔ 최종 확인
- [ ] 인터넷 없이 서비스 정상 동작
- [ ] 동일 이미지로 반복 배포 가능
- [ ] 운영자가 쉽게 사용할 수 있음

---

## 저장소 점검 결과 (2026-03-20)
아래는 `저장소 기준`으로 확인/보완 가능한 항목입니다. VM 런타임 검증이 필요한 항목은 기존 체크리스트를 유지합니다.

### 보완 완료 (repo-level)
- [x] 정적 IP 설정 스크립트 제공
  `scripts/set_static_ip.sh`
- [x] hostname 변경 + hosts fallback 스크립트 제공
  `scripts/set_hostname_hosts.sh`
- [x] 서비스 관리 명령 제공 (svc-up/down)
  `scripts/svc-up.sh`, `scripts/svc-down.sh`
- [x] 백업/복구 스크립트 제공
  `scripts/backup_platform.sh`, `scripts/restore_platform.sh`
- [x] `/opt/company/*` 구조 생성 스크립트 제공
  `scripts/provision_company_layout.sh`
- [x] first boot 처리 스크립트 제공 (machine-id/SSH key 재생성)
  `scripts/first_boot_init.sh`
- [x] 문서 5종 추가
  `INSTALL.md`, `QUICKSTART.md`, `TROUBLESHOOTING.md`, `PORTS.md`, `CHANGELOG.md`

### 기존 저장소에서 이미 확인된 항목 (repo-level)
- [x] Kubernetes manifest 포함 (`infra/k8s/*`)
- [x] frontend/backend 포함 (`apps/frontend`, `apps/backend`)
- [x] health check script (`scripts/healthcheck.sh`, `scripts/verify.sh`)
- [x] Node/npm 캐시 또는 오프라인 번들 구성 (`scripts/prepare_offline_bundle.sh`)
- [x] Python wheelhouse 준비 로직 (`scripts/prepare_offline_bundle.sh`)

### VM 빌드/운영 단계에서 최종 검증 필요
- [ ] 보안 정책(root SSH 제한, sudo 정책) 실적용 확인
- [ ] qemu-guest-agent 필요 여부/적용 확인 (VMware 환경은 open-vm-tools 중심)
- [ ] ingress 실적용 정책 확인
- [ ] 이미지 정리/로그 초기화/cloud-init 정리 최종 스냅샷 확인
- [ ] 인터넷 완전 차단 환경에서 end-to-end 동작 검증
