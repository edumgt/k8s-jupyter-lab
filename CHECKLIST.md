# VMware 3-node OVA Rebuild Checklist

이 문서는 `start.sh`(구성/검증) + `ovabuild.sh`(OVA export) 기반으로 매번 OVA를 다시 생성할 때 사용하는 운영 체크리스트입니다.

## 1) 변경 반영 전

- [ ] Git 작업 트리 정리 (`git status`)
- [ ] 이번 빌드에 포함할 코드/매니페스트 변경 범위 확정
- [ ] `README.md`, `docs/vmware/README.md` 변경사항 동기화 여부 확인
- [ ] `packer/variables.vmware.auto.pkrvars.hcl` 점검
- [ ] `iso_url`, `iso_checksum`, `output_directory`, `vmware_workstation_path`, `ovftool_path_windows` 확인

## 2) 빌드/프로비저닝/검증 실행

- [ ] `start.sh` 실행 옵션 기록
- [ ] 필요 시 `--seed-gitlab-be-fe`, `--post-reboot-check`, `--strict-harbor-check` 옵션 포함
- [ ] 예시 명령:

```bash
bash ./start.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --static-network \
  --control-plane-ip 192.168.56.10 \
  --worker1-ip 192.168.56.11 \
  --worker2-ip 192.168.56.12 \
  --gateway 192.168.56.1 \
  --metallb-range 192.168.56.240-192.168.56.250 \
  --ingress-lb-ip 192.168.56.240 \
  --seed-gitlab-be-fe \
  --post-reboot-check
```

- [ ] 실행 중 출력된 전체 `Step 1..N` 단계 성공 여부 확인
- [ ] 실패 시 에러 단계 기록 후 `TROUBLESHOOTING.md`에 원인 추가

## 2-1) 최종 OVA export 실행

- [ ] 최종 export는 `ovabuild.sh`로 실행
- [ ] 예시 명령:

```bash
bash ./ovabuild.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --control-plane-ip 192.168.56.10 \
  --ingress-lb-ip 192.168.56.240 \
  --dist-dir C:/ffmpeg
```

## 3) 자동 검증 결과 확인

- [ ] 노드 3대 `Ready` 확인
- [ ] `data-platform-dev` 네임스페이스 핵심 Pod `Running` 확인
- [ ] PVC `Bound` 확인 (`jupyter-workspace`, `nexus-data`, `gitlab-*`)
- [ ] 노드 배치 확인
- [ ] `backend`, `jupyter` -> `k8s-worker-1`
- [ ] `gitlab`, `nexus`, `mongodb`, `redis`, `airflow` -> `k8s-worker-2`
- [ ] `frontend` -> worker 노드 배치(컨트롤플레인 미배치)
- [ ] Ingress URL 점검(`platform.local`, `gitlab.platform.local`, `nexus.platform.local` 등)

## 4) 수동 기능 점검

- [ ] PC 재기동/수동 Power On 이후 `bash scripts/vmware_post_reboot_verify.sh ...` 실행
- [ ] FE 로그인(`test1@test.com` / `admin@test.com`) 확인
- [ ] 사용자 Jupyter 세션 생성/종료 확인
- [ ] Jupyter snapshot publish/restore 확인
- [ ] GitLab clone/commit/push 확인
- [ ] `dev1/platform-backend`, `dev2/platform-frontend` clone 확인
- [ ] Nexus Python/npm 의존성 설치 확인
- [ ] code-server + Vite 개발 서버 확인(필요 시)

## 5) OVA 산출물 점검

- [ ] `k8s-data-platform.ova`, `k8s-worker-1.ova`, `k8s-worker-2.ova` 생성 확인
- [ ] OVA 파일 크기/생성 시간 확인
- [ ] 해시값(`sha256sum`) 생성/보관
- [ ] 폐쇄망 전달용 폴더에 OVA + offline-bundle + 문서 복사

## 6) 폐쇄망 전달 패키지

- [ ] OVA 3개
- [ ] `dist/offline-bundle` 또는 동등 번들
- [ ] hosts 예시 파일
- [ ] 운영 실행 문서(README, vmware guide, CHECKLIST)
- [ ] 릴리스 노트/변경 요약

## 7) 빌드 결과 기록

- [ ] 빌드 일시:
- [ ] 커밋 SHA:
- [ ] `start.sh` 실행 옵션:
- [ ] Ingress LB IP:
- [ ] OVA 저장 경로:
- [ ] Known issues:
