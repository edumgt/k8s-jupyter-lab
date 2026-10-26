# k8s-jupyter — Air-gap AI Agent Platform (VMware OVA)

🌐 **English** | [中文](docs/i18n/README.zh.md) | [日本語](docs/i18n/README.ja.md) | [한국어](readme-kr.md)

An automation repository for building a **GPU-based Local LLM + AI Agent development/operations platform** by porting VMs as VMware OVAs into a customer's **air-gapped** environment.

---

## Tech Stack

### Platform / Infrastructure

- `VMware OVA`
- `Ubuntu 24.04`
- `Kubernetes`
- `containerd`
- `NVIDIA GPU / CUDA`
- `Harbor`, `Nexus`, `GitLab`, `NAS (OpenMediaVault)`

### AI / Development Stack

- `Ollama`, `vLLM`, `TGI`
- `JupyterHub`
- `LangGraph`, `AutoGen`
- `Chroma`, `Milvus`

### Local Development Toolchain

- `Visual Studio Code`
- Local LLM inference via `Ollama`
- Local coding agent combining `Codex CLI` + `Ollama (--oss)`
- Local coding agent combining `Claude Code` + `Ollama`
- `Node.js / npm`, `Git for Windows`
- Optional: a custom local agent sidebar as a `VSCode Extension`

### Offline (Air-gap) Development Principles

- Even without internet access, `Ollama` with pre-downloaded models can write code, refactor, explain code, and draft tests
- `Codex CLI` and `Claude Code` can be configured to read/modify files and run commands against the local working directory
- Web search, up-to-date documentation lookup, installing new packages, and remote Git integration are limited without internet access or an internal mirror
- Before bringing assets into the air-gapped network, it is recommended to pre-bundle `models`, `pip/npm/apt dependencies`, `documentation`, and `example code`
- For agent work on large codebases, a larger context window is advantageous, so raising the `Ollama` context length is recommended

### Windows Local Development Helper Script

- [setup-windows-ollama-dev.ps1](setup-windows-ollama-dev.ps1)
- Purpose: automates `Codex CLI`, `Claude Code`, local model pulls, and VSCode integration checks in a `Windows + VSCode + Ollama + local GPU` environment

### VS Code Local Agent Extension

- [tools/vscode-local-agent/README.md](tools/vscode-local-agent/README.md)
- Purpose: adds a `Local Agent` icon to the VS Code Activity Bar, providing a sidebar chat panel that calls Windows Ollama (`http://172.29.32.1:11434`) from WSL
- Run: from the root workspace, press `F5` or use `Run and Debug > Run Local Ollama Agent Extension`

---

## Architecture Diagrams

### 1. Overall Delivery Pipeline

```mermaid
graph LR
    subgraph BUILD["Online Build Environment"]
        ISO["Ubuntu 24.04 ISO"] --> PACKER["Packer Build"]
        PACKER --> ANSIBLE["Ansible Provisioning"]
        ANSIBLE --> OVF["OVA files x8"]
        ANSIBLE --> BUNDLE["Offline Bundle"]
    end

    OVF --> MEDIA["Transfer Media USB/HDD"]
    BUNDLE --> MEDIA

    subgraph AIRGAP["Customer Air-gapped Network"]
        INFRA["Infra VM Deployment\nHarbor, Nexus, GitLab, NAS"]
        K8S_VM["Kubernetes Deployment\nCP + Worker x3"]
        PLATFORM["AI Platform Operations"]
        GPU_WL["GPU Workloads\nLLM, AI Agent, Jupyter"]
        INFRA --> PLATFORM
        K8S_VM --> PLATFORM
        PLATFORM --> GPU_WL
    end

    MEDIA --> INFRA
    MEDIA --> K8S_VM
```

---

### 2. Customer Air-gapped VM Layout (8 VMs)

```mermaid
graph TB
    subgraph INFRA_VMS["Infra VMs"]
        HARBOR["harbor-32\nHarbor Registry\n:80, :443"]
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

        subgraph K8S_STACK["K8s Platform Stack"]
            MLB["MetalLB L2 LB"]
            NGINX["ingress-nginx\n:80, :443"]
            METRICS["metrics-server"]
            HEADLAMP["Headlamp Dashboard"]
        end
    end

    subgraph AI_WL["AI Workloads"]
        LLM["Local LLM\nOllama, vLLM, TGI"]
        JUPYTER["JupyterHub\nDev Environment"]
        AGENT["AI Agent\nLangGraph, AutoGen"]
    end

    NAS -->|"NFS PV"| CP
    HARBOR -->|"image pull"| CP
    NEXUS -->|"packages"| CP
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

### 3. GPU Passthrough Architecture

```mermaid
graph TB
    subgraph HOST["VMware Workstation Host Windows"]
        GPU_HW["Physical GPU NVIDIA"]
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
        LLM_ENGINE["LLM Inference Engine\nvLLM, Ollama"]
        CUDA --> LLM_ENGINE
    end

    VMWARE --> GPU_DEV
    CONTAINERD -->|"gpu resource limit"| CUDA
```

---

### 4. AI Agent Development Workflow

```mermaid
graph LR
    BROWSER["Developer\nBrowser"]

    subgraph PLATFORM["AI Platform K8s"]
        JUPYTER_SVC["JupyterHub :443"]
        AGENT_SVC["AI Agent Service\nREST API"]
        LLM_SVC["Local LLM\nOllama :11434\nvLLM :8000"]
        VECTOR_DB["Vector DB\nChroma, Milvus"]
    end

    subgraph STORAGE["NAS Storage"]
        MODEL_STORE["LLM Model Files\nGGUF, Safetensors"]
        DATA_STORE["Training / RAG Data"]
    end

    subgraph REGISTRY["Registries"]
        HARBOR_REG["Harbor\nAI Container Images"]
        NEXUS_REG["Nexus\npip Package Mirror"]
    end

    BROWSER -->|"HTTPS"| JUPYTER_SVC
    BROWSER -->|"HTTPS"| AGENT_SVC
    JUPYTER_SVC -->|"LLM API"| LLM_SVC
    AGENT_SVC -->|"LLM API"| LLM_SVC
    AGENT_SVC -->|"RAG search"| VECTOR_DB
    LLM_SVC -->|"load model"| MODEL_STORE
    VECTOR_DB --- DATA_STORE
    HARBOR_REG -->|"image pull"| JUPYTER_SVC
    NEXUS_REG -->|"pip install"| JUPYTER_SVC
```

---

### 5. OVA Build Details (Packer)

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
    PLAYBOOK --> VMX["vmx build output"]

    VMX -->|"ovftool"| OVA_K8S["k8s OVA x4\ncp, worker-1, worker-2, worker-3"]
    VMX -->|"ovftool"| OVA_SVC["service OVA x4\nnexus, harbor, gitlab, nas-omv"]
    OVA_K8S --> SHA["SHA256SUMS.txt"]
    OVA_SVC --> SHA
```

---

### 6. Offline Bundle Import Flow

```mermaid
graph LR
    subgraph BUNDLE["offline-bundle directory"]
        IMGS["images tar\ncontainer images"]
        MFST["manifests yaml\nK8s resource definitions"]
        APT_PKG["apt-bundle\ndeb packages"]
        MODELS["models\nLLM model files"]
    end

    IMGS -->|"ctr images import"| CTR["containerd\nk8s.io namespace"]
    MFST -->|"kubectl apply -f"| KUBE_API["Kubernetes API"]
    APT_PKG -->|"dpkg -i"| OS_PKG["OS packages\nNVIDIA driver"]
    MODELS -->|"NFS PV"| LLM_POD["LLM Pod\nload model"]

    CTR --> PODS["Pod image serving"]
    KUBE_API --> SVCS["Service, Ingress\ncreated"]
```

---

## VM Inventory

| VM | Role | Key Services | Ports |
| ---- | ------ | ---------- | ------ |
| `cp` | Kubernetes Control Plane | kube-apiserver, etcd, scheduler | 6443, 2379-2380 |
| `w1` | Kubernetes Worker + GPU | kubelet, containerd, NVIDIA runtime | 10250 |
| `w2` | Kubernetes Worker + GPU | kubelet, containerd, NVIDIA runtime | 10250 |
| `w3` | Kubernetes Worker + GPU | kubelet, containerd, NVIDIA runtime | 10250 |
| `nexus-31` | Nexus Repository | apt mirror, pip mirror, helm chart | 8081 |
| `harbor-32` | Harbor Registry | Container image registry | 80, 443 |
| `nas-omv` | NAS (OpenMediaVault) | NFS, SMB shared storage | 2049(NFS) |
| `gitlab-33` | GitLab | Source control, CI/CD | 80, 443, 22 |

---

## Key Directories

```text
.
├── packer/         # VM/OVA image build definitions (vmware-iso)
├── scripts/        # VM networking, install, import, verification automation
└── docs/           # Phase-by-phase operations documentation
```

---

## Quick Start

```bash
# Phase 1: Build OVA (online environment)
bash scripts/phase1_build_ova_assets.sh all

# Phase 2: Prepare air-gap operations after booting the OVA
bash scripts/phase2_operate_airgap_cluster.sh all

# Phase 3: Install in the air-gapped network
bash scripts/phase3_install_from_completed_ova.sh full

# Check status
bash scripts/status_k8s.sh
bash scripts/check_vm_airgap_status.sh
```

---

## Installation Procedure (OVA-based)

### 1. Prerequisites

- 8 OVA files (cp, w1~3, nexus, harbor, gitlab, nas-omv)
- Offline bundle (`images/*.tar`, `manifests/`, `apt-bundle/`, `models/`)

### 2. Basic VM Setup (each node)

```bash
sudo bash scripts/set_static_ip.sh --ip <IP> --prefix 24 --gateway <GW>
sudo bash scripts/set_hostname_hosts.sh --hostname <HOSTNAME> --entry "<IP> <HOSTNAME>"
```

### 3. Import Offline Bundle

```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --apply
```

### 4. Post-install Checks

```bash
bash scripts/status_k8s.sh
bash scripts/check_vm_airgap_status.sh
kubectl get nodes -o wide
kubectl get pods -A
```

### 5. Rebuild OVA (if needed)

```bash
bash ovabuild.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl --dist-dir C:/ffmpeg
```

---

## Troubleshooting

### Kubernetes Basic Status

```bash
bash scripts/status_k8s.sh
kubectl get nodes -o wide && kubectl get pods -A
```

### containerd / kubelet Issues

```bash
sudo systemctl restart containerd kubelet
sudo systemctl status containerd kubelet --no-pager
```

### Offline Image Import Failure

```bash
bash scripts/import_offline_bundle.sh --bundle-dir /opt/k8s-data-platform/offline-bundle --runtime-only
```

### VM Network Issues

```bash
ip a && ip route && cat /etc/hosts
sudo bash scripts/set_static_ip.sh --ip <IP> --prefix 24 --gateway <GW>
```

---

## Documentation Map

| Document | Content |
| ------ | ------ |
| `docs/phase-1-build-ova.md` | OVA build (online) |
| `docs/phase-2-ova-solution-ops.md` | Operations prep after booting OVA |
| `docs/phase-3-install-airgap-from-ova.md` | Air-gapped installation |
| `docs/checklist.md` | Build/deploy/rehearsal checklist |
| `PORTS.md` | Port list |
| `CHANGELOG.md` | Change history |
| `docs/docs-map.md` | Full documentation index |
