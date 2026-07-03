# CHECKLIST.md
## OVA 빌드/배포 통합 체크리스트

## A. Golden Image 기본 점검
- [ ] 시간대/locale 설정
- [ ] 필수 패키지 설치
- [ ] cloud-init/임시 캐시 정리
- [ ] SSH 정책 점검
- [ ] sudo 권한 정책 점검
- [ ] 기본 계정 비밀번호 변경
- [ ] DHCP/정적 IP 전환 가능
- [ ] hostname 변경 스크립트 동작
- [ ] `/etc/hosts` 기본 엔트리 점검
- [ ] 오프라인 패키지 번들 포함
- [ ] 컨테이너 이미지 tar 포함
- [ ] 기본 매니페스트 포함
- [ ] containerd 정상
- [ ] kubelet 정상
- [ ] 노드 Ready 확인

## B. VMware OVA 재빌드 점검
- [ ] `git status` clean 확인
- [ ] `packer/variables.vmware.auto.pkrvars.hcl` 값 점검
- [ ] 출력 경로(`--dist-dir`) 확인
- [ ] `bash scripts/build_vmware_ova_and_verify.sh --vars-file ...` 실행
- [ ] VM 부팅/기본 상태 확인

## C. Export 점검
- [ ] `bash ovabuild.sh --vars-file ... --dist-dir ...` 실행
- [ ] OVA 파일 생성 확인
- [ ] SHA256 생성 확인

## D. 폐쇄망 리허설
- [ ] 오프라인 번들 반입 테스트
- [ ] 설치 스크립트 실행 테스트
- [ ] 장애복구 절차 테스트
- [ ] 폐쇄망 재설치 리허설 완료
