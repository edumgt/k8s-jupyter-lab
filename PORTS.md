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
