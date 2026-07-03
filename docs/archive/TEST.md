# Kubernetes Test Snapshot (2026-03-19)

🌐 [English](TEST.en.md) | [中文](TEST.zh.md) | [日本語](TEST.ja.md) | **한국어**

## 1) Current VM and Node IP Summary

| VM Name | Kubernetes Node | Role | State | Internal IP |
|---|---|---|---|---|
| k8s-data-platform | k8s-data-platform | control-plane | Running / Ready | 10.77.0.4 |
| k8s-worker-1 | k8s-worker-1 | worker | Running / Ready | 10.77.0.5 |
| k8s-worker-2 | k8s-worker-2 | worker | Running / Ready | 10.77.0.6 |
| k8s-worker-3 | removed | worker | Stopped | 10.77.0.7 (old) |

Running VMs (`VBoxManage list runningvms`):
- k8s-data-platform
- k8s-worker-1
- k8s-worker-2

Current Kubernetes nodes (`kubectl get nodes -o wide`):
- k8s-data-platform (10.77.0.4)
- k8s-worker-1 (10.77.0.5)
- k8s-worker-2 (10.77.0.6)

---

## 2) Service IP and NodePort Summary (`data-platform-dev`)

| Service | Type | ClusterIP | Service Port | NodePort | Access Example |
|---|---|---|---|---|---|
| airflow | NodePort | 10.99.64.233 | 8080/TCP | 30090 | `http://10.77.0.5:30090` |
| backend | NodePort | 10.108.80.33 | 8000/TCP | 30081 | `http://10.77.0.5:30081` |
| frontend | NodePort | 10.101.40.171 | 80/TCP | 30080 | `http://10.77.0.5:30080` |
| gitlab-web | NodePort | 10.102.234.133 | 8929/TCP, 22/TCP | 30089, 30224 | `http://10.77.0.5:30089`, `ssh -p 30224 ...` |
| jupyter | NodePort | 10.99.190.56 | 8888/TCP | 30088 | `http://10.77.0.5:30088` |
| nexus | NodePort | 10.98.114.37 | 8081/TCP | 30091 | `http://10.77.0.5:30091` |
| mongodb | ClusterIP | 10.106.245.2 | 27017/TCP | none | internal only |
| redis | ClusterIP | 10.96.125.129 | 6379/TCP | none | internal only |

### 2.1 Windows Browser Access (frontend NodePort 30080)

Important:
- `10.101.40.171` is a Kubernetes `ClusterIP`, so Windows browser cannot open it directly.
- Use `Node IP + NodePort`: `http://10.77.0.5:30080`

From Windows PowerShell, test connectivity first:

```powershell
Test-NetConnection 10.77.0.5 -Port 30080
```

If `TcpTestSucceeded = True`, open:
- `http://10.77.0.5:30080`

If it fails, add VirtualBox NAT port-forwarding and use localhost:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "frontend:tcp:[127.0.0.1]:30080:[10.77.0.5]:30080"
```

Then open:
- `http://127.0.0.1:30080`

### 2.2 Localhost Mode (`127.0.0.1`) - Additional NodePort Forwarding

When accessing the frontend with `http://127.0.0.1:30080`:
- frontend page loads on `30080`
- frontend API calls go to backend `30081`, so backend forwarding is also required

Minimum required additional forwarding:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "backend:tcp:[127.0.0.1]:30081:[10.77.0.5]:30081"
```

Recommended commonly used forwarding rules:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "jupyter:tcp:[127.0.0.1]:30088:[10.77.0.5]:30088"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "gitlab-web:tcp:[127.0.0.1]:30089:[10.77.0.5]:30089"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "airflow:tcp:[127.0.0.1]:30090:[10.77.0.5]:30090"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "nexus:tcp:[127.0.0.1]:30091:[10.77.0.5]:30091"
```

Note:
- Personal JupyterLab sessions use dynamically assigned NodePort values.
- If you use localhost-only access, add an extra temporary forwarding rule for the assigned Jupyter NodePort shown in the frontend status.

---

## 3) SSH Rules Applied (Done)

Applied NAT network SSH forwarding rules:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-cp:tcp:[127.0.0.1]:2222:[10.77.0.4]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w1:tcp:[127.0.0.1]:2201:[10.77.0.5]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w2:tcp:[127.0.0.1]:2202:[10.77.0.6]:22"
```

Windows host connectivity check:
- `127.0.0.1:2222` = open
- `127.0.0.1:2201` = open
- `127.0.0.1:2202` = open

Default account/password:
- username: `ubuntu`
- password: `ubuntu`

---

## 4) SSH Access from Windows and WSL

### 4.1 Windows terminal

```bash
ssh ubuntu@127.0.0.1 -p 2222   # control-plane
ssh ubuntu@127.0.0.1 -p 2201   # worker-1
ssh ubuntu@127.0.0.1 -p 2202   # worker-2
```

### 4.2 WSL terminal (recommended, reliable in this environment)

Use Windows OpenSSH client directly from WSL:

```bash
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2222
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2201
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2202
```

Why this method:
- In this environment, native WSL Linux `ssh` to forwarded localhost ports may fail depending on WSL localhost forwarding mode.
- Windows `ssh.exe` always uses Windows networking stack, so it reaches VBox forwarded ports reliably.

### 4.3 Alternative (inside control-plane VM)

```bash
ssh ubuntu@10.77.0.5   # worker-1
ssh ubuntu@10.77.0.6   # worker-2
```

---

## 5) Move These VMs to Another VirtualBox Host

Recommended method: export/import OVA.

### 5.1 On source host (current PC)

1. Power off VMs.
2. Export OVA files:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-data-platform poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-1 poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-2 poweroff

& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-data-platform --output C:\ffmpeg\k8s-data-platform.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-1 --output C:\ffmpeg\k8s-worker-1.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-2 --output C:\ffmpeg\k8s-worker-2.ova
```

Quick copy block (PowerShell):

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-data-platform poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-1 poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-2 poweroff

& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-data-platform --output C:\ffmpeg\k8s-data-platform.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-1 --output C:\ffmpeg\k8s-worker-1.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-2 --output C:\ffmpeg\k8s-worker-2.ova
```

3. Copy `.ova` files to target PC.

### 5.2 On target host (other VirtualBox PC)

Import OVAs:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-data-platform.ova --vsys 0 --vmname k8s-data-platform
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-worker-1.ova --vsys 0 --vmname k8s-worker-1
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-worker-2.ova --vsys 0 --vmname k8s-worker-2
```

---

## 6) Network Setup After Import (Important)

Create (or update) NAT network:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork add --netname k8s-data-platform-net --network 10.77.0.0/24 --dhcp on --enable
```

If it already exists, run:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --network 10.77.0.0/24 --dhcp on --enable
```

Attach NIC1 of each VM to the NAT network:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-data-platform --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-1 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-2 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
```

Apply SSH forwarding rules again on target host:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-cp:tcp:[127.0.0.1]:2222:[10.77.0.4]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w1:tcp:[127.0.0.1]:2201:[10.77.0.5]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w2:tcp:[127.0.0.1]:2202:[10.77.0.6]:22"
```

---

## 7) Bring-Up and Post-Boot Checks

Start order:
1. control-plane (`k8s-data-platform`)
2. worker-1
3. worker-2

Commands:

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-data-platform --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-1 --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-2 --type headless
```

Inside control-plane:

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
```

If stale `k8s-worker-3` node appears:

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node k8s-worker-3 --ignore-not-found
```

---

## 8) Add New Worker Node to Existing Cluster

아래는 `k8s-worker-3` 같은 새 worker VM 을 추가해 기존 control-plane(`k8s-data-platform`) 클러스터에 조인시키는 절차입니다.

### 8.1 VM 생성/네트워크 연결 (VirtualBox)

1. 새 VM 준비 (clone/import 중 택1).
2. NIC1 을 기존 NAT network(`k8s-data-platform-net`)에 연결.
3. 필요 시 SSH 포워딩 규칙 추가 (예: `2203 -> 10.77.0.7:22`).

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-3 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w3:tcp:[127.0.0.1]:2203:[10.77.0.7]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-3 --type headless
```

### 8.2 control-plane 에서 join 명령 생성

`k8s-data-platform`(control-plane) 안에서 실행:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf bash /opt/k8s-data-platform/scripts/generate_join_command.sh 10.77.0.4
```

- 출력되는 `kubeadm join ...` 명령은 기본 TTL(`2h`)이므로 만료 전에 worker에서 실행해야 합니다.
- 토큰 만료 시 위 명령을 다시 실행해 새 join 명령을 발급하면 됩니다.

### 8.3 새 worker 에서 join 실행

새 worker VM 안에서 실행:

```bash
sudo bash /opt/k8s-data-platform/scripts/join_worker_node.sh \
  --hostname k8s-worker-3 \
  --join-command "<control-plane에서 생성한 kubeadm join ...>"
```

### 8.4 조인 확인 및 worker 라벨 정리

다시 control-plane 에서 실행:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl label node k8s-worker-3 node-role.kubernetes.io/worker=worker --overwrite
```

선택 사항(멀티노드 오버레이 라벨 일괄 정리):

```bash
bash /opt/k8s-data-platform/scripts/configure_multinode_cluster.sh \
  --env dev \
  --overlay dev-multinode \
  --workers k8s-worker-1,k8s-worker-2,k8s-worker-3 \
  --skip-reset
```

### 8.5 트러블슈팅

- `preflight` 충돌/재조인 문제 시 worker에서 reset 후 재시도:

```bash
sudo kubeadm reset -f --cri-socket=unix:///run/containerd/containerd.sock
sudo systemctl restart containerd kubelet
```

- control-plane에서 `NotReady`로 보이면 worker의 시간 동기화, 네트워크(10.77.0.0/24), `kubelet/containerd` 상태를 우선 확인.

---

## 9) VMware Import (Settings and Cautions)

Use this section when importing the same OVA into VMware Workstation/Player.

### 9.1 Recommended VMware VM Settings

- vCPU: 4 or more
- Memory: 16 GB or more
- Disk: 100 GB or more recommended
- Firmware: keep default from imported OVA (change only if boot fails)
- Network Adapter: `Bridged` recommended for direct NodePort access from host browser

### 9.2 Import Steps (VMware)

1. Open VMware Workstation/Player.
2. Import/Open `k8s-data-platform.ova`.
3. Review CPU/Memory/Disk and finish import.
4. Boot VM and log in with:
   - username: `ubuntu`
   - password: `ubuntu`

### 9.3 First Checks After Boot

Inside VM:

```bash
hostname -I
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev
```

### 9.4 Host Browser Access (VMware)

In VMware mode, prefer direct `VM_IP + NodePort` access.

Examples:
- `http://<VM_IP>:30080` (frontend)
- `http://<VM_IP>:30081` (backend)
- `http://<VM_IP>:30088` (jupyter shared)
- `http://<VM_IP>:30089` (gitlab web)

### 9.5 Important Cautions

- VirtualBox NAT forwarding commands in this document (`VBoxManage natnetwork ... --port-forward-4`) do not apply to VMware.
- `127.0.0.1:2222`, `2201`, `2202` SSH forwarding examples are VirtualBox-specific.
- If firewall is enabled inside VM, NodePort range may need to be allowed:
  - `sudo ufw allow 30000:32767/tcp`
- If `kubectl` falls back to `localhost:8080`, force kubeconfig:
  - `sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes`
- Multi-node auto bootstrap script in this repo is VirtualBox-only:
  - `scripts/bootstrap_virtualbox_multinode.ps1`
  - For VMware multi-node, worker clone/join/network setup is manual.

### 9.6 Reference

- VMware detailed guide: `docs/vmware/README.md`


###
```
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.11 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
```
```
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.12 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
```
```
sudo bash /opt/k8s-data-platform/scripts/set_static_ip.sh --ip 192.168.56.10 --prefix 24 --gateway 192.168.56.1 --dns 192.168.56.1,1.1.1.1,8.8.8.8
```