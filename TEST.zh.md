# Kubernetes 测试快照（2026-03-19）

🌐 [English](TEST.en.md) | **中文** | [日本語](TEST.ja.md) | [한국어](TEST.md)

## 1) 当前 VM 和节点 IP 汇总

| VM 名称 | Kubernetes 节点 | 角色 | 状态 | 内部 IP |
|---|---|---|---|---|
| k8s-data-platform | k8s-data-platform | control-plane | 运行中 / Ready | 10.77.0.4 |
| k8s-worker-1 | k8s-worker-1 | worker | 运行中 / Ready | 10.77.0.5 |
| k8s-worker-2 | k8s-worker-2 | worker | 运行中 / Ready | 10.77.0.6 |
| k8s-worker-3 | 已移除 | worker | 已停止 | 10.77.0.7（旧） |

正在运行的 VM（`VBoxManage list runningvms`）：
- k8s-data-platform
- k8s-worker-1
- k8s-worker-2

当前 Kubernetes 节点（`kubectl get nodes -o wide`）：
- k8s-data-platform (10.77.0.4)
- k8s-worker-1 (10.77.0.5)
- k8s-worker-2 (10.77.0.6)

---

## 2) 服务 IP 和 NodePort 汇总（`data-platform-dev`）

| 服务 | 类型 | ClusterIP | 服务端口 | NodePort | 访问示例 |
|---|---|---|---|---|---|
| airflow | NodePort | 10.99.64.233 | 8080/TCP | 30090 | `http://10.77.0.5:30090` |
| backend | NodePort | 10.108.80.33 | 8000/TCP | 30081 | `http://10.77.0.5:30081` |
| frontend | NodePort | 10.101.40.171 | 80/TCP | 30080 | `http://10.77.0.5:30080` |
| gitlab-web | NodePort | 10.102.234.133 | 8929/TCP, 22/TCP | 30089, 30224 | `http://10.77.0.5:30089`，`ssh -p 30224 ...` |
| jupyter | NodePort | 10.99.190.56 | 8888/TCP | 30088 | `http://10.77.0.5:30088` |
| nexus | NodePort | 10.98.114.37 | 8081/TCP | 30091 | `http://10.77.0.5:30091` |
| mongodb | ClusterIP | 10.106.245.2 | 27017/TCP | 无 | 仅内部 |
| redis | ClusterIP | 10.96.125.129 | 6379/TCP | 无 | 仅内部 |

### 2.1 Windows 浏览器访问（frontend NodePort 30080）

注意：
- `10.101.40.171` 是 Kubernetes `ClusterIP`，Windows 浏览器无法直接访问。
- 请使用 `节点 IP + NodePort`：`http://10.77.0.5:30080`

在 Windows PowerShell 中先测试连通性：

```powershell
Test-NetConnection 10.77.0.5 -Port 30080
```

若 `TcpTestSucceeded = True`，打开：
- `http://10.77.0.5:30080`

若失败，添加 VirtualBox NAT 端口转发并使用 localhost：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "frontend:tcp:[127.0.0.1]:30080:[10.77.0.5]:30080"
```

然后打开：
- `http://127.0.0.1:30080`

### 2.2 Localhost 模式（`127.0.0.1`）— 额外 NodePort 转发

使用 `http://127.0.0.1:30080` 访问 frontend 时：
- frontend 页面在 `30080` 加载
- frontend API 调用 backend `30081`，因此也需要 backend 转发

最少需要的额外转发：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "backend:tcp:[127.0.0.1]:30081:[10.77.0.5]:30081"
```

推荐常用转发规则：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "jupyter:tcp:[127.0.0.1]:30088:[10.77.0.5]:30088"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "gitlab-web:tcp:[127.0.0.1]:30089:[10.77.0.5]:30089"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "airflow:tcp:[127.0.0.1]:30090:[10.77.0.5]:30090"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "nexus:tcp:[127.0.0.1]:30091:[10.77.0.5]:30091"
```

注意：
- 个人 JupyterLab 会话使用动态分配的 NodePort。
- 如果只使用 localhost 访问，请为 frontend 状态中显示的 Jupyter NodePort 添加临时转发规则。

---

## 3) 已应用的 SSH 规则

已应用的 NAT 网络 SSH 转发规则：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-cp:tcp:[127.0.0.1]:2222:[10.77.0.4]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w1:tcp:[127.0.0.1]:2201:[10.77.0.5]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w2:tcp:[127.0.0.1]:2202:[10.77.0.6]:22"
```

Windows 主机连通性检查：
- `127.0.0.1:2222` = 开放
- `127.0.0.1:2201` = 开放
- `127.0.0.1:2202` = 开放

默认账号/密码：
- 用户名：`ubuntu`
- 密码：`ubuntu`

---

## 4) 从 Windows 和 WSL 进行 SSH 访问

### 4.1 Windows 终端

```bash
ssh ubuntu@127.0.0.1 -p 2222   # control-plane
ssh ubuntu@127.0.0.1 -p 2201   # worker-1
ssh ubuntu@127.0.0.1 -p 2202   # worker-2
```

### 4.2 WSL 终端（推荐，在此环境中可靠）

直接从 WSL 使用 Windows OpenSSH 客户端：

```bash
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2222
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2201
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2202
```

原因：
- 在此环境中，WSL Linux 原生 `ssh` 连接转发的 localhost 端口可能因 WSL localhost 转发模式而失败。
- Windows `ssh.exe` 始终使用 Windows 网络栈，因此能可靠地访问 VBox 转发的端口。

### 4.3 备选方案（在 control-plane VM 内部）

```bash
ssh ubuntu@10.77.0.5   # worker-1
ssh ubuntu@10.77.0.6   # worker-2
```

---

## 5) 将这些 VM 迁移到另一台 VirtualBox 主机

推荐方法：导出/导入 OVA。

### 5.1 在源主机（当前 PC）

1. 关闭 VM。
2. 导出 OVA 文件：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-data-platform poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-1 poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-2 poweroff

& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-data-platform --output C:\ffmpeg\k8s-data-platform.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-1 --output C:\ffmpeg\k8s-worker-1.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-2 --output C:\ffmpeg\k8s-worker-2.ova
```

3. 将 `.ova` 文件复制到目标 PC。

### 5.2 在目标主机（其他 VirtualBox PC）

导入 OVA：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-data-platform.ova --vsys 0 --vmname k8s-data-platform
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-worker-1.ova --vsys 0 --vmname k8s-worker-1
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-worker-2.ova --vsys 0 --vmname k8s-worker-2
```

---

## 6) 导入后的网络设置（重要）

创建（或更新）NAT 网络：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork add --netname k8s-data-platform-net --network 10.77.0.0/24 --dhcp on --enable
```

若已存在，运行：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --network 10.77.0.0/24 --dhcp on --enable
```

将每台 VM 的 NIC1 连接到 NAT 网络：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-data-platform --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-1 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-2 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
```

在目标主机上重新应用 SSH 转发规则：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-cp:tcp:[127.0.0.1]:2222:[10.77.0.4]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w1:tcp:[127.0.0.1]:2201:[10.77.0.5]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w2:tcp:[127.0.0.1]:2202:[10.77.0.6]:22"
```

---

## 7) 启动和启动后检查

启动顺序：
1. control-plane（`k8s-data-platform`）
2. worker-1
3. worker-2

命令：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-data-platform --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-1 --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-2 --type headless
```

在 control-plane 内部：

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
```

若出现旧的 `k8s-worker-3` 节点：

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node k8s-worker-3 --ignore-not-found
```

---

## 8) VMware 导入（设置和注意事项）

在将同一 OVA 导入 VMware Workstation/Player 时使用本节。

### 8.1 推荐 VMware VM 设置

- vCPU：4 个或以上
- 内存：16 GB 或以上
- 磁盘：建议 100 GB 或以上
- 固件：保持导入 OVA 的默认值（仅在启动失败时更改）
- 网络适配器：推荐 `Bridged`，以便从主机浏览器直接访问 NodePort

### 8.2 导入步骤（VMware）

1. 打开 VMware Workstation/Player。
2. 导入/打开 `k8s-data-platform.ova`。
3. 检查 CPU/内存/磁盘并完成导入。
4. 启动 VM 并使用以下凭据登录：
   - 用户名：`ubuntu`
   - 密码：`ubuntu`

### 8.3 启动后首次检查

在 VM 内部：

```bash
hostname -I
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev
```

### 8.4 主机浏览器访问（VMware）

VMware 模式下，优先使用 `VM_IP + NodePort` 直接访问。

示例：
- `http://<VM_IP>:30080`（frontend）
- `http://<VM_IP>:30081`（backend）
- `http://<VM_IP>:30088`（jupyter shared）
- `http://<VM_IP>:30089`（gitlab web）

### 8.5 重要注意事项

- 本文档中的 VirtualBox NAT 转发命令（`VBoxManage natnetwork ... --port-forward-4`）不适用于 VMware。
- `127.0.0.1:2222`、`2201`、`2202` SSH 转发示例为 VirtualBox 专用。
- 若 VM 内部启用了防火墙，可能需要允许 NodePort 范围：
  - `sudo ufw allow 30000:32767/tcp`
- 若 `kubectl` 回退到 `localhost:8080`，请强制指定 kubeconfig：
  - `sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes`
- 本仓库中的多节点自动引导脚本仅适用于 VirtualBox：
  - `scripts/bootstrap_virtualbox_multinode.ps1`
  - VMware 多节点需手动克隆/加入/配置网络。

### 8.6 参考

- VMware 详细指南：`docs/vmware/README.md`
