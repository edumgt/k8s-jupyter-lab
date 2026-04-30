# PORTS.md
## 포트 목록

## Kubernetes / Infra
- `22/tcp`: SSH
- `6443/tcp`: Kubernetes API
- `8472/udp`: Flannel VXLAN

## Platform NodePort (`data-platform-dev`)
- `30080/tcp`: Frontend
- `30081/tcp`: Backend
- `30088/tcp`: Jupyter
- `30089/tcp`: GitLab Web
- `30224/tcp`: GitLab SSH
- `30090/tcp`: Airflow
- `30091/tcp`: Nexus
- `30092/tcp`: Harbor (구성 시)
- `30100/tcp`: code-server
- `31080/tcp`: Frontend Vite Dev

## 내부 서비스 포트 (ClusterIP/Pod)
- `27017/tcp`: MongoDB
- `6379/tcp`: Redis
- `8080/tcp`: Airflow 내부 서비스
- `8081/tcp`: Nexus 내부 서비스
- `8929/tcp`: GitLab 내부 Web

