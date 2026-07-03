# k8s-jupyter — 内网隔离（Air-gap）AI Agent 平台（VMware OVA）

🌐 [English](README.en.md) | **中文** | [日本語](README.ja.md) | [한국어](../../README.md)

将虚拟机以 VMware OVA 形式移植到客户**内网隔离（air-gap）**环境，
用于构建**基于 GPU 的本地 LLM + AI Agent 开发/运维平台**的自动化仓库。

---

## 技术栈

### 平台/基础设施

- `VMware OVA`
- `Ubuntu 24.04`
- `Kubernetes`
- `containerd`
- `NVIDIA GPU / CUDA`
- `Harbor`, `Nexus`, `GitLab`, `NAS (OpenMediaVault)`

### AI/开发栈

- `Ollama`, `vLLM`, `TGI`
- `JupyterHub`
- `LangGraph`, `AutoGen`
- `Chroma`, `Milvus`

### 本地开发工具链

- `Visual Studio Code`
- 基于 `Ollama` 的本地 LLM 推理
- `Codex CLI` + `Ollama (--oss)` 组合的本地编码代理
- `Claude Code` + `Ollama` 组合的本地编码代理
- `Node.js / npm`, `Git for Windows`
- 可选：以 `VSCode Extension` 形式提供的自定义本地代理侧边栏

### 离线（air-gap）开发原则

- 即使没有互联网，也可以使用预先下载好的 `Ollama` 模型进行代码编写、重构、说明和测试草稿生成
- `Codex CLI` 与 `Claude Code` 可以基于本地工作目录构建文件读写/命令执行工作流
- 网络搜索、最新文档查阅、新包安装、远程 Git 集成在没有互联网或企业内部镜像的情况下会受限
- 建议在带入内网隔离环境前,预先打包好 `模型`、`pip/npm/apt 依赖`、`文档`、`示例代码`
- 面向大型代码库的代理任务更适合较大的上下文,建议提高 `Ollama` 的上下文长度配置

### Windows 本地开发辅助脚本

- [setup-windows-ollama-dev.ps1](/home/ubuntu/k8s-jupyter/setup-windows-ollama-dev.ps1)
- 目的：在 `Windows + VSCode + Ollama + 本地 GPU` 环境中自动化 `Codex CLI`、`Claude Code`、本地模型拉取、VSCode 集成检查

### VS Code 本地代理扩展

- [tools/vscode-local-agent/README.md](/home/ubuntu/k8s-jupyter/tools/vscode-local-agent/README.md)
- 目的：在 VS Code 左侧 `Activity Bar` 添加 `Local Agent` 图标,提供从 WSL 调用 Windows Ollama（`http://172.29.32.1:11434`）的侧边栏聊天面板
- 运行方式：在根工作区按 `F5`，或选择 `Run and Debug > Run Local Ollama Agent Extension`

---

## 架构图

### 1. 整体交付流水线

```mermaid
graph LR
    subgraph BUILD["在线构建环境"]
        ISO["Ubuntu 24.04 ISO"] --> PACKER["Packer Build"]
        PACKER --> ANSIBLE["Ansible 配置"]
        ANSIBLE --> OVF["OVA 文件 x8"]
        ANSIBLE --> BUNDLE["离线包"]
    end

    OVF --> MEDIA["转移介质 USB/HDD"]
    BUNDLE --> MEDIA

    subgraph AIRGAP["客户内网隔离环境"]
        INFRA["基础设施 VM 部署\nHarbor, Nexus, GitLab, NAS"]
        K8S_VM["Kubernetes 部署\nCP + Worker x3"]
        PLATFORM["AI 平台运维"]
        GPU_WL["GPU 工作负载\nLLM, AI Agent, Jupyter"]
        INFRA --> PLATFORM
        K8S_VM --> PLATFORM
        PLATFORM --> GPU_WL
    end

    MEDIA --> INFRA
    MEDIA --> K8S_VM
```

---

### 2. 客户内网隔离环境 VM 组成（8台）

```mermaid
graph TB
    subgraph INFRA_VMS["基础设施 VM"]
        HARBOR["harbor-32\nHarbor 镜像仓库\n:80, :443"]
        NEXUS["nexus-31\nNexus Repository\n:8081"]
        GITLAB["gitlab-33\nGitLab\n:80, :443, :22"]
        NAS["nas-omv\nNAS OpenMediaVault\nNFS, SMB"]
    end

    subgraph K8S_CLUSTER["Kubernetes Cluster"]
        CP["cp Control Plane\nkube-apiserver :6443\netcd :2379-2380"]

        subgraph WORKERS["Worker Nodes GPU"]
            W1["w1 worker-1\nGPU, kubelet, containerd"]
            W2["w2 worker-2\nGPU, kubelet, containerd"]
            W3["w3 worker-3\nGPU, kubelet, containerd"]
        end

        subgraph K8S_STACK["K8s 平台栈"]
            MLB["MetalLB L2 LB"]
            NGINX["ingress-nginx\n:80, :443"]
            METRICS["metrics-server"]
            HEADLAMP["Headlamp Dashboard"]
        end
    end

    subgraph AI_WL["AI 工作负载"]
        LLM["Local LLM\nOllama, vLLM, TGI"]
        JUPYTER["JupyterHub\n开发环境"]
        AGENT["AI Agent\nLangGraph, AutoGen"]
    end

    NAS -->|"NFS PV"| CP
    HARBOR -->|"镜像 pull"| CP
    NEXUS -->|"软件包"| CP
    GITLAB -->|"CI/CD"| CP
    CP --> W1
    CP --> W2
    CP --> W3
    HEADLAMP --> LLM
    MLB --> NGINX
    NGINX --> JUPYTER
    LLM -->|"API"| AGENT
    AGENT --> JUPYTER
```

---

### 3. GPU 直通结构

```mermaid
graph TB
    subgraph HOST["VMware Workstation Host Windows"]
        GPU_HW["物理 GPU NVIDIA"]
        VMWARE["VMware Hypervisor"]
        GPU_HW -->|"PCIe Passthrough or vGPU"| VMWARE
    end

    subgraph VM_WORKER["Worker VM Ubuntu 24.04"]
        GPU_DEV["NVIDIA Driver\nnvidia device"]
        CONTAINERD["containerd\nnvidia-container-runtime"]
        GPU_DEV --> CONTAINERD
    end

    subgraph POD["Kubernetes Pod"]
        CUDA["CUDA Context"]
        LLM_ENGINE["LLM 推理引擎\nvLLM, Ollama"]
        CUDA --> LLM_ENGINE
    end

    VMWARE --> GPU_DEV
    CONTAINERD -->|"gpu resource limit"| CUDA
```

---

### 4. AI Agent 开发工作流

```mermaid
graph LR
    BROWSER["开发者\n浏览器"]

    subgraph PLATFORM["AI 平台 K8s"]
        JUPYTER_SVC["JupyterHub :443"]
        AGENT_SVC["AI Agent 服务\nREST API"]
        LLM_SVC["Local LLM\nOllama :11434\nvLLM :8000"]
        VECTOR_DB["Vector DB\nChroma, Milvus"]
    end

    subgraph STORAGE["NAS 存储"]
        MODEL_STORE["LLM 模型文件\nGGUF, Safetensors"]
        DATA_STORE["训练/RAG 数据"]
    end

    subgraph REGISTRY["镜像仓库"]
        HARBOR_REG["Harbor\nAI 容器镜像"]
        NEXUS_REG["Nexus\npip 包镜像"]
    end

    BROWSER -->|"HTTPS"| JUPYTER_SVC
    BROWSER -->|"HTTPS"| AGENT_SVC
    JUPYTER_SVC -->|"LLM API"| LLM_SVC
    AGENT_SVC -->|"LLM API"| LLM_SVC
    AGENT_SVC -->|"RAG 检索"| VECTOR_DB
    LLM_SVC -->|"加载模型"| MODEL_STORE
    VECTOR_DB --- DATA_STORE
    HARBOR_REG -->|"镜像 pull"| JUPYTER_SVC
    NEXUS_REG -->|"pip install"| JUPYTER_SVC
```

---

### 5. OVA 构建详情（Packer）

```mermaid
graph TD
    VARS["variables.vmware.pkrvars.hcl"]
    ISO_FILE["Ubuntu 24.04 ISO local"]

    subgraph PACKER_BUILD["Packer Build vmware-iso"]
        CLOUD_INIT["cloud-init autoinstall\nHTTP nocloud"]
        FILE_COPY["File Provisioner\nscripts, docs, manifests"]
        APT_INST["apt install\nansible, open-vm-tools"]
        PLAYBOOK["ansible-playbook\nplaybook-proof.yml"]
        CLOUD_INIT --> FILE_COPY --> APT_INST --> PLAYBOOK
    end

    VARS --> CLOUD_INIT
    ISO_FILE --> CLOUD_INIT
    PLAYBOOK --> VMX["vmx 构建产物"]

    VMX -->|"ovftool"| OVA_K8S["k8s OVA x4\ncp, worker-1, worker-2, worker-3"]
    VMX -->|"ovftool"| OVA_SVC["服务 OVA x4\nnexus, harbor, gitlab, nas-omv"]
    OVA_K8S --> SHA["SHA256SUMS.txt"]
    OVA_SVC --> SHA
```

---

### 6. 离线包导入流程

```mermaid
graph LR
    subgraph BUNDLE["offline-bundle 目录"]
        IMGS["images tar\n容器镜像"]
        MFST["manifests yaml\nK8s 资源定义"]
        APT_PKG["apt-bundle\ndeb 软件包"]
        MODELS["models\nLLM 模型文件"]
    end

    IMGS -->|"ctr images import"| CTR["containerd\nk8s.io namespace"]
    MFST -->|"kubectl apply -f"| KUBE_API["Kubernetes API"]
    APT_PKG -->|"dpkg -i"| OS_PKG["OS 软件包\nNVIDIA driver"]
    MODELS -->|"NFS PV"| LLM_POD["LLM Pod\n加载模型"]

    CTR --> PODS["Pod 镜像服务"]
    KUBE_API --> SVCS["Service, Ingress\n创建完成"]
```

---

## VM 清单

| VM | 角色 | 主要服务 | 端口 |
| ---- | ------ | ---------- | ------ |
| `cp` | Kubernetes Control Plane | kube-apiserver, etcd, scheduler | 6443, 2379-2380 |
| `w1` | Kubernetes Worker + GPU | kubelet, containerd, NVIDIA runtime | 10250 |
| `w2` | Kubernetes Worker + GPU | kubelet, containerd, NVIDIA runtime | 10250 |
| `w3` | Kubernetes Worker + GPU | kubelet, containerd, NVIDIA runtime | 10250 |
| `nexus-31` | Nexus Repository | apt mirror, pip mirror, helm chart | 8081 |
| `harbor-32` | Harbor Registry | 容器镜像仓库 | 80, 443 |
| `nas-omv` | NAS (OpenMediaVault) | NFS, SMB 共享存储 | 2049(NFS) |
| `gitlab-33` | GitLab | 源代码管理, CI/CD | 80, 443, 22 |

---

## 核心目录

```text
.
├── packer/         # VM/OVA 镜像构建定义 (vmware-iso)
├── scripts/        # VM 网络/安装/导入/验证自动化
└── docs/           # 分阶段运维文档
```

---

## 快速开始

```bash
# Phase 1: 构建 OVA（在线环境）
bash scripts/phase1_build_ova_assets.sh all

# Phase 2: OVA 启动后的 air-gap 运维准备
bash scripts/phase2_operate_airgap_cluster.sh all

# Phase 3: 内网隔离环境安装
bash scripts/phase3_install_from_completed_ova.sh full

# 状态检查
bash scripts/status_k8s.sh
bash scripts/check_vm_airgap_status.sh
```

---

## 安装步骤（基于 OVA）

### 1. 准备事项

- OVA 文件 8 个（cp, w1~3, nexus, harbor, gitlab, nas-omv）
- 离线包（`images/*.tar`, `manifests/`, `apt-bundle/`, `models/`）

### 2. VM 基本设置（各节点）

```bash
sudo bash scripts/set_static_ip.sh --ip <IP> --prefix 24 --gateway <GW>
sudo bash scripts/set_hostname_hosts.sh --hostname <HOSTNAME> --entry "<IP> <HOSTNAME>"
```

### 3. 导入离线包

```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --apply
```

### 4. 安装后检查

```bash
bash scripts/status_k8s.sh
bash scripts/check_vm_airgap_status.sh
kubectl get nodes -o wide
kubectl get pods -A
```

### 5. 重新生成 OVA（如需要）

```bash
bash ovabuild.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl --dist-dir C:/ffmpeg
```

---

## 故障处理

### Kubernetes 基本状态

```bash
bash scripts/status_k8s.sh
kubectl get nodes -o wide && kubectl get pods -A
```

### containerd / kubelet 异常

```bash
sudo systemctl restart containerd kubelet
sudo systemctl status containerd kubelet --no-pager
```

### 离线镜像导入失败

```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --runtime-only
```

### VM 网络问题

```bash
ip a && ip route && cat /etc/hosts
sudo bash scripts/set_static_ip.sh --ip <IP> --prefix 24 --gateway <GW>
```

---

## 文档地图

| 文档 | 内容 |
| ------ | ------ |
| `docs/phase-1-build-ova.md` | OVA 构建（在线） |
| `docs/phase-2-ova-solution-ops.md` | OVA 启动后运维准备 |
| `docs/phase-3-install-airgap-from-ova.md` | 内网隔离环境安装 |
| `CHECKLIST.md` | 构建/部署/演练检查清单 |
| `PORTS.md` | 端口列表 |
| `CHANGELOG.md` | 变更历史 |
