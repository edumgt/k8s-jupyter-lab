# INSTALL.md

## Air-gap 빠른 설치 (3 OVA + init.sh 1개)

이 문서는 아래 시나리오만 대상으로 합니다.

- OVA 3개가 이미 **오프라인 실행에 필요한 이미지/스크립트/번들**을 내장
- 설치 PC는 air-gap(인터넷 차단) 상태
- 운영자는 VMware에서 VM import 후, VM 내부에서 IP/hostname만 분리
- WSL에서는 `init.sh` 하나로 전체 흐름 진행

---

## 1) 준비물

필수 파일:

- `k8s-data-platform.ova`
- `k8s-worker-1.ova`
- `k8s-worker-2.ova`
- `init.sh` (이 저장소 루트)

권장 OVA 위치:

- `C:\ffmpeg\k8s-data-platform.ova`
- `C:\ffmpeg\k8s-worker-1.ova`
- `C:\ffmpeg\k8s-worker-2.ova`

기본 네트워크 값:

- control-plane: `k8s-data-platform` / `192.168.56.10`
- worker-1: `k8s-worker-1` / `192.168.56.11`
- worker-2: `k8s-worker-2` / `192.168.56.12`
- gateway: `192.168.56.1`
- MetalLB: `192.168.56.240-192.168.56.250`
- ingress LB IP: `192.168.56.240`

---

## 2) VMware 네트워크 기준

VMware Workstation의 Host-only 네트워크를 아래처럼 맞춥니다.

- Subnet: `192.168.56.0`
- Mask: `255.255.255.0`
- Host adapter IP(Windows VMware VMnet 어댑터): `192.168.56.1`

확인(WSL):

```bash
powershell.exe -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | ? InterfaceAlias -like 'VMware Network Adapter VMnet*' | sort InterfaceAlias | ft InterfaceAlias,IPAddress,PrefixLength -Auto"
```

`VMware Network Adapter VMnet1` 가 `192.168.56.1/24` 이면 정상입니다.

---

## 3) 한 번에 설치 (권장)

저장소 루트에서 실행:

```bash
bash init.sh --all
```

### `--all`이 하는 일 (현재 기본)

1. OVA 3개 import
2. VM별 static IP/hostname 설정 명령 출력
3. VM 수동 설정 완료까지 **pause**
4. WSL route 적용
5. WSL/Windows hosts 적용
6. `start.sh` 실행

중요:

- 기본 모드는 `airgap-preloaded` 입니다.
- 따라서 `--all`은 preload 단계를 자동 생략합니다.
- `start.sh` 실행 시 자동으로 `--skip-nexus-prime --skip-export`가 붙습니다.
  - 폐쇄망에서 외부 레지스트리/외부 seed 접근 시도를 줄이기 위함

---

## 4) VM 콘솔에서 해야 하는 작업 (pause 시점)

`init.sh --all` 중간에 VM별 명령이 출력되면,
VMware 콘솔에서 각 VM에 로그인해 해당 명령을 실행합니다.

예시(각 VM 공통 패턴):

```bash
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.10 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
sudo bash /opt/k8s-data-platform/scripts/set_hostname_hosts.sh --hostname k8s-data-platform --entry "192.168.56.10 k8s-data-platform" --entry "192.168.56.11 k8s-worker-1" --entry "192.168.56.12 k8s-worker-2"
hostname
hostname -I
ip route
```


```bash
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.11 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
sudo bash /opt/k8s-data-platform/scripts/set_hostname_hosts.sh --hostname k8s-worker-1 --entry "192.168.56.10 k8s-data-platform" --entry "192.168.56.11 k8s-worker-1" --entry "192.168.56.12 k8s-worker-2"
hostname
hostname -I
ip route
```

```bash
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.12 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
sudo bash /opt/k8s-data-platform/scripts/set_hostname_hosts.sh --hostname k8s-worker-2 --entry "192.168.56.10 k8s-data-platform" --entry "192.168.56.11 k8s-worker-1" --entry "192.168.56.12 k8s-worker-2"
hostname
hostname -I
ip route
```

3대 모두 분리 완료 후, `init.sh` 터미널로 돌아와 Enter를 누르면 다음 단계로 진행합니다.

---

![alt text](image-2.png)

## 5) 접속 준비 - PC 등 외부 hosts 파일 수정

---
```
bash init.sh --apply-windows-hosts --ingress-lb-ip 192.168.56.240 --wsl-route-gateway 172.29.32.1
```

`init.sh`가 hosts까지 반영하면 아래 도메인 사용 가능:

- `platform.local`
- `jupyter.platform.local`
- `gitlab.platform.local`
- `airflow.platform.local`
- `nexus.platform.local`

수동 확인:

```bash
grep -n 'platform.local' /etc/hosts
powershell.exe -NoProfile -Command "Get-Content 'C:\Windows\System32\drivers\etc\hosts' | Select-String 'platform.local'"
```

---

## 6) 설치 후 점검

기본 점검:

```bash
curl -I http://platform.local
curl -I http://nexus.platform.local
curl -I http://gitlab.platform.local
```

클러스터 점검(control-plane VM 안에서):

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -A -o wide
```

---

## 7) 필요 시 분리 실행

### 7-1) VM 명령만 출력

```bash
bash init.sh --vm-commands
```

### 7-2) import만 실행

```bash
bash init.sh --import-ova
```

### 7-3) start만 실행

```bash
bash init.sh --run-start
```

---

## 8) Legacy preload 모드 (선택)

아래는 "OVA 내장이 불완전해서 preload를 다시 수행해야 할 때"만 사용합니다.

```bash
bash init.sh --all --legacy-preload --preload-skip-build
```

참고:

- `--legacy-preload`를 켜면 `--all`에 preload 단계가 다시 포함됩니다.
- 완전 air-gap 환경에서는 기존 번들 재사용(`--preload-skip-build`)을 권장합니다.

---

## 9) 트러블슈팅

### 9-1) VMware 좌측 라이브러리에 VM이 안 보임

`ovftool` import는 라이브러리 자동 등록이 안 될 수 있습니다.

- VMware `File > Open`으로 아래 3개를 직접 등록:
  - `C:\ffmpeg\output-k8s-data-platform-vmware\k8s-data-platform.vmx`
  - `C:\ffmpeg\output-k8s-data-platform-vmware\k8s-worker-1\k8s-worker-1.vmx`
  - `C:\ffmpeg\output-k8s-data-platform-vmware\k8s-worker-2\k8s-worker-2.vmx`

### 9-2) `docker.io` pull 시도가 보임

현재 기본 배포 기준은 `harbor.local/data-platform/*` 입니다.

점검:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get deploy,statefulset -n data-platform-dev -o custom-columns=NAME:.metadata.name,IMAGES:.spec.template.spec.containers[*].image
```

모든 이미지가 `harbor.local/data-platform/` 로 시작해야 정상입니다.

복구:

```bash
bash scripts/apply_k8s.sh --env dev --overlay dev-3node
```

위 재적용 후에도 일부 노드에서 `ImagePullBackOff`가 나면, 해당 노드 runtime 에 Harbor 태그 이미지가 없는 상태이므로 오프라인 번들 preload(또는 이미지 import)를 다시 수행하세요.

### 9-3) `Pause for VM setup requires interactive stdin` 오류

비대화형 터미널에서 실행한 경우입니다.

1. VM 콘솔에서 IP/hostname 수동 변경 먼저 완료
2. 아래처럼 재실행:

```bash
bash init.sh --all --no-pause-for-vm-setup
```

---

## 10) 운영 메모

- 폐쇄망 운영 기준은 **외부 pull이 아닌 OVA 내장 자산 + preload된 런타임 이미지**입니다.
- 최종 배포 검증 후 OVA를 다시 export할 때는 별도 `ovabuild.sh` 절차를 사용합니다.
