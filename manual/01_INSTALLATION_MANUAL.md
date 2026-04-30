# 설치 매뉴얼 (고객사 납품용)

## 1. 목적

본 문서는 인터넷이 없는 환경(air-gap)에서 플랫폼을 설치/검증하기 위한 표준 절차를 제공합니다.

## 2. 구성 개요

- OS/가상화: Ubuntu 24 기반 OVA, VMware Workstation
- 클러스터: kubeadm Kubernetes (3-node)
- 배포 방식: Kubernetes manifest + kustomize overlay
- 주요 서비스:
  - Frontend: `http://platform.local`
  - Backend Docs: `http://platform.local/docs`
  - Jupyter: `http://jupyter.platform.local/lab`
  - GitLab: `http://gitlab.platform.local`
  - Airflow: `http://airflow.platform.local`
  - Nexus: `http://nexus.platform.local`

## 3. 사전 준비

### 3.1 필수 산출물

1. `k8s-data-platform.ova`
2. `k8s-worker-1.ova`
3. `k8s-worker-2.ova`
4. 설치 저장소(본 repo) 또는 최소 실행 스크립트 세트

### 3.2 네트워크 기준값(권장)

1. Subnet: `192.168.56.0/24`
2. Gateway: `192.168.56.1`
3. Control-plane: `192.168.56.10`
4. Worker-1: `192.168.56.11`
5. Worker-2: `192.168.56.12`
6. MetalLB range: `192.168.56.240-192.168.56.250`
7. Ingress LB IP: `192.168.56.240`

## 4. 설치 절차

### 4.1 OVA Import

VMware에서 OVA 3개를 import합니다.

### 4.2 VM 네트워크/호스트명 설정

각 VM 콘솔에서 정적 IP와 hostname을 설정합니다.

예시(control-plane):

```bash
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.10 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
sudo bash /opt/k8s-data-platform/scripts/set_hostname_hosts.sh --hostname k8s-data-platform --entry "192.168.56.10 k8s-data-platform" --entry "192.168.56.11 k8s-worker-1" --entry "192.168.56.12 k8s-worker-2"
```

### 4.3 원샷 설치 실행

WSL(저장소 루트)에서 실행:

```bash
bash init.sh --all
```

필요 시 정적 네트워크 파라미터를 명시:

```bash
bash ./start.sh \
  --static-network \
  --control-plane-ip 192.168.56.10 \
  --worker1-ip 192.168.56.11 \
  --worker2-ip 192.168.56.12 \
  --gateway 192.168.56.1 \
  --metallb-range 192.168.56.240-192.168.56.250 \
  --ingress-lb-ip 192.168.56.240
```

### 4.4 hosts 적용

Windows/WSL hosts에 아래 도메인을 등록합니다.

```text
192.168.56.240 platform.local
192.168.56.240 jupyter.platform.local
192.168.56.240 gitlab.platform.local
192.168.56.240 airflow.platform.local
192.168.56.240 nexus.platform.local
192.168.56.240 dashboard.platform.local
```

## 5. 설치 검증

### 5.1 클러스터 상태

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A -o wide
```

### 5.2 Ingress 검증

```bash
bash scripts/verify.sh --http-mode ingress --lb-ip 192.168.56.240
```

### 5.3 URL 확인

```bash
curl -I http://platform.local
curl -I http://gitlab.platform.local
curl -I http://airflow.platform.local
curl -I http://nexus.platform.local
```

## 6. 기본 관리자 계정(초기값)

1. Platform Admin: `admin@test.com / 123456`
2. GitLab: `root / v7Q#2mL!9xC@4pR%8tZ`
3. Airflow: `admin / admin12345!`
4. Nexus: `admin / nexus123!`

주의: 납품 후 운영 전 반드시 비밀번호를 변경하십시오.

## 7. 오프라인(air-gap) 필수 확인

1. `harbor.local/data-platform/*` 이미지가 노드 runtime에 존재해야 함
2. `/opt/k8s-data-platform/offline-bundle` 경로(또는 동등 bundle) 준비
3. 외부 레지스트리 참조 없이 pod 기동 가능해야 함

점검:

```bash
bash scripts/check_offline_readiness.sh
```

## 8. 설치 실패 시 우선 조치

1. `kubectl get pods -A`에서 `ImagePullBackOff` 확인
2. 오프라인 번들 재적재
3. `bash scripts/apply_k8s.sh --env dev --overlay dev-3node` 재적용
4. `bash scripts/verify.sh --http-mode ingress --lb-ip <LB_IP>` 재검증

