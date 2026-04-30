# Phase 3: 완성 OVA 복사/설치 문서 (air-gap)

## 목적

완성된 OVA 3개를 다른 PC(폐쇄망 포함)로 복사한 뒤, VMware import + 초기 설치를 수행합니다.

## 준비물

- `k8s-data-platform.ova`
- `k8s-worker-1.ova`
- `k8s-worker-2.ova`
- 저장소 루트의 `init.sh`
- `scripts/phase3_install_from_completed_ova.sh`

권장 OVA 위치:

- `C:\ffmpeg\k8s-data-platform.ova`
- `C:\ffmpeg\k8s-worker-1.ova`
- `C:\ffmpeg\k8s-worker-2.ova`

## 사용 스크립트 (3단계 전용 진입점)

- `scripts/phase3_install_from_completed_ova.sh`

내부적으로 `init.sh`를 단계별 옵션으로 호출합니다.

## 기본 실행

import부터 hosts/start까지 전체 진행:

```bash
bash scripts/phase3_install_from_completed_ova.sh full \
  --ova-dir C:/ffmpeg \
  --control-plane-ip 192.168.56.10 \
  --worker1-ip 192.168.56.11 \
  --worker2-ip 192.168.56.12 \
  --gateway 192.168.56.1 \
  --ingress-lb-ip 192.168.56.240 \
  --metallb-range 192.168.56.240-192.168.56.250
```

## 상황별 실행

OVA import는 이미 끝난 경우:

```bash
bash scripts/phase3_install_from_completed_ova.sh continue \
  --control-plane-ip 192.168.56.10 \
  --worker1-ip 192.168.56.11 \
  --worker2-ip 192.168.56.12
```

hosts만 갱신:

```bash
bash scripts/phase3_install_from_completed_ova.sh hosts-only \
  --ingress-lb-ip 192.168.56.240
```

start 단계만 재실행:

```bash
bash scripts/phase3_install_from_completed_ova.sh start-only -- --skip-export --skip-nexus-prime
```

## 완료 후 접속 URL

- `http://platform.local`
- `http://jupyter.platform.local`
- `http://gitlab.platform.local`
- `http://airflow.platform.local`
- `http://nexus.platform.local`

