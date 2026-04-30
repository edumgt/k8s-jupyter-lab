# QUICKSTART.md
## 빠른 시작 (5분)

## 1) 플랫폼 기동

```bash
bash scripts/svc-up.sh --env dev
```

## 2) 상태 확인

```bash
bash scripts/status_k8s.sh --env dev
bash scripts/verify.sh --env dev --host 127.0.0.1 --http-timeout 10
```

## 3) 주요 서비스
- Frontend: `http://<VM_IP>:30080`
- Backend API docs: `http://<VM_IP>:30081/docs`
- Jupyter: `http://<VM_IP>:30088`
- GitLab: `http://<VM_IP>:30089`
- Nexus: `http://<VM_IP>:30091`

## 4) 종료

```bash
bash scripts/svc-down.sh --env dev
```

