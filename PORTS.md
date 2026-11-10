# PORTS.md
## 포트 목록 (VM/Cluster 기본)

## 필수 포트
- `22/tcp`: SSH
- `6443/tcp`: Kubernetes API Server
- `10250/tcp`: kubelet API
- `2379-2380/tcp`: etcd
- `4789/udp`: CNI VXLAN (환경별)

## 권장 점검 포트
- `80/tcp`, `443/tcp`: Ingress
- `30000-32767/tcp`: NodePort 범위(사용 시)

## 로컬 air-gap mock (`127.0.0.1` only)

`bash scripts/quickstart_airgap_mock.sh` 가 여는 포트입니다. OVA NodePort와 번호를 맞춥니다.

- `30080/tcp`: Frontend
- `30081/tcp`: Backend
- `30083/tcp`: Harbor mock
- `30088/tcp`: Jupyter
- `30089/tcp`: GitLab mock
- `30090/tcp`: Airflow mock
- `30091/tcp`: Nexus mock
