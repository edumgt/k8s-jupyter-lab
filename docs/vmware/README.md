# VMware 실행 가이드 (Repo 다운로드부터 구동까지)

이 문서는 **VMware 방식**으로 이 저장소를 실행하는 과정을 정리합니다.

## 1) 사전 준비

- OS: Windows 10/11 (권장)
- VMware Workstation Pro/Player 설치
- Git 설치
- 선택: WSL2 (OVA를 직접 빌드할 경우 편리)

기본 계정(OVA 내부):
- username: `ubuntu`
- password: `ubuntu`

## 2) 저장소 다운로드

```bash
git clone https://github.com/<your-org>/Kubernetes-Jupyter-Sandbox.git
cd Kubernetes-Jupyter-Sandbox
```

## 3) VMware 기반 빌드/검증/export 순서

### 3-0) 원샷 오케스트레이터(start.sh, 권장)

루트 `start.sh`는 아래 단계들을 순차 실행합니다.

- `scripts/vmware_provision_3node.sh` (3-node 재구성 + join + overlay + ingress/metallb)
- 노드/파드/PVC/노드 배치 점검
- `scripts/verify.sh`(Ingress URL 점검)
- `scripts/setup_nexus_offline.sh`(선택)

```bash
bash ./start.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl
```

기본 동작은 기존 VMX 3개가 있으면 VM 삭제/packer 빌드를 건너뛰고, VM 기동 후 Pod/URL 검증 위주로 진행합니다.

최종 OVA export는 루트 `ovabuild.sh`를 사용합니다.

```bash
bash ./ovabuild.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --control-plane-ip 192.168.56.10 \
  --ingress-lb-ip 192.168.56.240 \
  --dist-dir C:/ffmpeg
```

재부팅 복원 점검 + GitLab BE/FE demo repo seed 포함:

```bash
bash ./start.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --seed-gitlab-be-fe \
  --post-reboot-check
```

PC 재기동 후 VMware에서 각 VM을 수동으로 Power On 했다면, 재빌드 없이 상태만 점검:

```bash
bash scripts/vmware_post_reboot_verify.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --control-plane-ip 192.168.56.10 \
  --ingress-lb-ip 192.168.56.240
```

### 3-1) VMware 변수 준비

`packer/variables.vmware.auto.pkrvars.hcl`에서 아래 항목을 환경에 맞게 수정합니다.

- `iso_url`, `iso_checksum`
- `vm_name`, `output_directory`
- `vmware_workstation_path`, `ovftool_path_windows`

주의:
- `output_directory`는 `C:/ffmpeg` 루트 대신 전용 하위 폴더(예: `C:/ffmpeg/output-k8s-data-platform-vmware`)로 지정하는 것을 권장합니다.
- 기존 출력 폴더가 이미 존재하면 빌드가 실패할 수 있으므로 `--force`로 재실행하거나 폴더를 정리하세요.

### 3-2) VM 빌드 (export 없음)

```bash
bash scripts/vmware_build_vm.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl
```

### 3-3) VM 부팅 + 기본 검증

```bash
bash scripts/vmware_verify_vm.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --vm-user ubuntu \
  --vm-password ubuntu \
  --env dev
```

### 3-4) VMware VM에서 실습/테스트

- 원하는 시나리오를 VM 내부에서 검증/사용합니다.
- 폐쇄망 이관용 기준 상태가 되면 다음 단계에서 OVA로 export 합니다.

### 3-5) 최종 OVA export

```bash
bash scripts/vmware_export_ova.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --dist-dir 'C:\ffmpeg'
```

산출물:
- `C:\ffmpeg\<vm_name>.ova`
- `C:\ffmpeg\packer-vmware-build.log`

### 3-6) 원샷 실행 (빌드 + 검증 + export)

```bash
bash scripts/build_vmware_ova_and_verify.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl
```

### 3-7) 원샷 3-node 자동 구성 (control-plane + worker-1 + worker-2)

아래 명령은 control-plane 1대 빌드 후 worker 2대를 clone 하고,
3대 부팅 + join + overlay + ingress-nginx/MetalLB 적용까지 자동 수행합니다.
기본값으로 VMX를 VMware Workstation UI에 등록하므로, 실행 후 `My Computer` 목록에서 3대 VM을 확인할 수 있습니다.

```bash
bash scripts/vmware_provision_3node.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl
```

이미 control-plane VM이 있고 worker 2대만 다시 만들려면:

```bash
bash scripts/vmware_provision_3node.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --skip-build \
  --force-recreate-workers \
  --skip-bootstrap \
  --vm-start-mode gui
```

기존 worker clone을 버리고 다시 만들려면:

```bash
bash scripts/vmware_provision_3node.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl --force-recreate-workers
```

정적 IP까지 함께 적용하려면:

```bash
bash scripts/vmware_provision_3node.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --static-network \
  --control-plane-ip 192.168.56.10 \
  --worker1-ip 192.168.56.11 \
  --worker2-ip 192.168.56.12 \
  --gateway 192.168.56.1
```

MetalLB 주소 대역을 직접 고정하려면:

```bash
bash scripts/vmware_provision_3node.sh \
  --vars-file packer/variables.vmware.auto.pkrvars.hcl \
  --static-network \
  --control-plane-ip 192.168.56.10 \
  --worker1-ip 192.168.56.11 \
  --worker2-ip 192.168.56.12 \
  --gateway 192.168.56.1 \
  --metallb-range 192.168.56.240-192.168.56.250 \
  --ingress-lb-ip 192.168.56.240
```

### 3-8) 3대 VM OVA 일괄 export

```bash
bash scripts/vmware_export_3node_ova.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl --dist-dir 'C:\ffmpeg'
```

## 4) VMware로 OVA Import

1. VMware Workstation 실행
2. `File > Open` 또는 `Import`로 생성된 OVA 파일 선택
3. 아래와 같은 경고가 나오면 `Retry`를 눌러 import를 다시 진행
   - `The import failed because ... did not pass OVF specification conformance or virtual hardware compliance checks.`
   - OVA 메타데이터/하드웨어 호환성 검사 결과에 따라 경고가 나올 수 있음
   - 일반적으로 `Retry` 후 import가 계속 진행됩니다.
4. VM 이름/저장 경로 지정
5. CPU/Memory 조정 (권장: CPU 4+, Memory 16GB+)
6. Network Adapter를 `Bridged` 권장
7. VM 부팅

## 5) VM 내부 상태 확인

VM 콘솔 로그인 후:

```bash
hostname -I
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev
```

## 6) 호스트 브라우저 접속 (Ingress URL)

`vmware_provision_3node.sh`가 완료되면 ingress LoadBalancer IP(예: `192.168.56.240`)가 출력됩니다.
호스트 OS의 `hosts` 파일에 아래 예시처럼 등록한 뒤 URL로 접속합니다.

Windows `C:\\Windows\\System32\\drivers\\etc\\hosts` 예시:

```text
192.168.56.240 platform.local
192.168.56.240 jupyter.platform.local
192.168.56.240 gitlab.platform.local
192.168.56.240 airflow.platform.local
192.168.56.240 nexus.platform.local
```

- Frontend: `http://platform.local`
- Backend docs: `http://platform.local/docs`
- Jupyter: `http://jupyter.platform.local/lab`
- GitLab: `http://gitlab.platform.local`
- Airflow: `http://airflow.platform.local`
- Nexus: `http://nexus.platform.local`

레거시 NodePort 점검이 필요하면:
- `bash scripts/verify.sh --http-mode nodeport --host <CONTROL_PLANE_IP>`
- `bash scripts/verify.sh --http-mode ingress --lb-ip <INGRESS_LB_IP>`

로그인 계정:
- user: `test1@test.com / 123456`
- user: `test2@test.com / 123456`
- admin: `admin@test.com / 123456`

## 6-1) 폐쇄망 개발용 Nexus 캐시 사전 워밍

Python(Backend/Jupyter) + Vue3/Quasar(npm) 개발 라이브러리를 Nexus에 미리 적재하려면:

```bash
bash scripts/setup_nexus_offline.sh \
  --namespace data-platform-dev \
  --nexus-url http://nexus.platform.local \
  --username admin \
  --password '<nexus-password>' \
  --python-seed-file scripts/offline/python-dev-seed.txt \
  --npm-seed-file scripts/offline/npm-dev-seed.txt
```

control-plane VM 내부에서 실행할 때는 아래 URL도 사용 가능합니다.

```bash
--nexus-url http://127.0.0.1:30091
```

## 7) 자주 발생하는 이슈

### VMware import 중 OVF compliance 오류가 뜨는 경우

- 예시 메시지:
  - `The import failed because ... did not pass OVF specification conformance or virtual hardware compliance checks.`
- 우선 `Retry`를 눌러 VMware의 완화된 import 모드로 다시 시도합니다.
- 이 경고는 OVA 자체가 완전히 깨졌다는 뜻보다는, VMware가 OVF/가상 하드웨어 메타데이터를 엄격하게 검사하면서 발생하는 경우가 많습니다.
- `Retry` 후 import가 완료되면 그대로 사용해도 됩니다.
- 그래도 실패하면 다음 순서로 확인합니다.
  - OVA 파일 경로를 영문/짧은 경로로 옮긴 뒤 다시 import
  - OVA를 다시 export 또는 다시 build
  - VMware import 완료 후 부팅이 안 되면 firmware 설정을 기본값 유지한 상태로 다시 import

### VMware import는 됐지만 부팅/동작이 이상한 경우

- CPU 4개 이상, Memory 16GB 이상으로 올린 뒤 다시 부팅합니다.
- Network Adapter는 우선 `Bridged`로 두고 VM 내부에서 `hostname -I`로 IP를 확인합니다.
- `kubectl` 확인 시 반드시 관리자 kubeconfig를 사용합니다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
```

### 부팅 중 `Failed to fork off sandboxing environment` / `Freezing execution` 이 뜨는 경우

- 예시 메시지:
  - `Failed to fork off sandboxing environment for executing generators: Protocol error`
  - `[!!!!!!] Failed to start up manager.`
  - `systemd[1]: Freezing execution.`
- 이 경우는 단순한 VMware import 경고가 아니라, Ubuntu 24.04 부팅 초기에 `systemd`가 멈춘 상태입니다.
- 화면에 `recovering journal` 이 보였다면 비정상 종료 직후 한 번 발생했을 가능성도 있으니, 우선 VM을 완전히 종료한 뒤 다시 켜 봅니다.
- 재부팅 후에도 같은 화면에서 멈추면 가장 확실한 복구 방법은 라이브 ISO 또는 복구 환경으로 부팅해서 `initramfs`를 다시 생성하는 것입니다.

예시 절차:

```bash
sudo mount /dev/sda2 /mnt
sudo mount --bind /dev /mnt/dev
sudo mount --bind /dev/pts /mnt/dev/pts
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo mount --bind /run /mnt/run
sudo chroot /mnt
update-initramfs -c -k all
exit
sudo reboot
```

주의:
- 루트 파티션이 `/dev/sda2`가 아닐 수 있으므로 실제 파티션명을 먼저 확인해야 합니다.
- 가능하면 Ubuntu Server 24.04 계열 ISO의 `Try Ubuntu` 또는 recovery shell에서 작업하는 편이 안전합니다.
- 복구 후 정상 부팅되면 아래 명령으로 상태를 다시 확인합니다.

```bash
hostname -I
sudo systemctl is-active docker containerd kubelet
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
```

### `ip -br a`에서 `ens32`가 `DOWN`으로 나오는 경우

- 이 상태에서는 VM이 네트워크를 못 잡아서 `hostname -I`가 비거나, 호스트에서 Ingress URL/NodePort 접근이 모두 실패합니다.
- 먼저 VMware VM 설정에서 아래 항목을 확인합니다.
  - `Network Adapter > Connected` 체크
  - `Network Adapter > Connect at power on` 체크
  - 우선 `Bridged` 사용 (필요하면 `Configure Adapters`에서 실제 사용 중인 호스트 NIC를 명시)
- 회사/학교망 정책으로 Bridged가 막히는 환경이면 일단 `NAT`로 전환해 통신 여부를 먼저 확인합니다.

VM 내부에서:

```bash
ip -br a
sudo ip link set ens32 up
sudo systemctl restart systemd-networkd
sudo networkctl reconfigure ens32
ip -4 addr show ens32
ip route
```

- `ens32`에 IPv4가 생기면 정상입니다.
- Ubuntu 24.04 이미지에 따라 `dhclient`가 기본 미설치일 수 있습니다. (`sudo: dhclient: command not found` 정상 가능)
- 그 다음 control-plane에서 `kubectl`이 정상인지 확인합니다.

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
```

- 위 절차 후에도 계속 IP가 안 생기면 netplan에 DHCP를 명시하고 재적용합니다.

```bash
sudo tee /etc/netplan/01-vmware-dhcp.yaml >/dev/null <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    ens32:
      dhcp4: true
EOF
sudo netplan generate
sudo netplan apply
sudo systemctl restart systemd-networkd
ip -4 addr show ens32
```

- 그래도 DHCP 임대가 안 잡히면(특히 Bridged/사내망 환경) VMware 네트워크를 `NAT`로 바꿔 우선 연결 여부를 확인합니다.
- `dhclient`를 꼭 써야 하면 아래 패키지를 설치합니다.

```bash
sudo apt-get update
sudo apt-get install -y isc-dhcp-client
sudo dhclient -v ens32
```

### kubectl이 `localhost:8080`으로 붙는 경우

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
```

### 화면은 열리는데 API 호출이 실패하는 경우

- 브라우저 URL과 API 포트 접근 방식을 통일합니다.
- VMware 3-node 구성에서는 `hosts` 등록 후 `http://platform.local` 접근을 권장합니다.

## 8) 멀티노드 관련 참고

- `scripts/bootstrap_virtualbox_multinode.ps1`는 이름 그대로 VirtualBox 자동화 스크립트입니다.
- VMware에서도 SSH 경로가 열려 있으면 `scripts/bootstrap_3node_k8s_ova.sh`로
  static IP + worker join + `dev-3node` overlay 적용까지 자동화할 수 있습니다.
- 실행 예시:

```bash
cp scripts/templates/3node-cluster.env.example /tmp/3node-cluster.env
vi /tmp/3node-cluster.env
bash scripts/bootstrap_3node_k8s_ova.sh --config /tmp/3node-cluster.env
```
