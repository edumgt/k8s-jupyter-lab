# SRE Checklist

- [ ] `systemctl status docker`, `systemctl status containerd`, `systemctl status kubelet` 가 모두 `active (running)` 인가
- [ ] `kubectl get nodes` 결과가 `Ready` 인가
- [ ] `kubectl get pods -n data-platform-dev` 또는 `data-platform-prod` 에서 backend, frontend, mongodb, redis, airflow, jupyter, gitlab 이 정상 기동되는가
- [ ] Frontend `30080`, Backend `30081`, Jupyter `30088`, GitLab `30089`, Airflow `30090` 접근이 가능한가
- [ ] Backend `/healthz` 에 MongoDB / Redis 상태가 반영되는가
- [ ] per-user Jupyter pod 가 `users/<session-id>` PVC subPath 를 마운트하는가
- [ ] Frontend 에서 `workspace_subpath`, `launch image`, `snapshot status` 가 보이는가
- [ ] Harbor snapshot publish Job 이 생성되고 완료되는가
- [ ] 다음 로그인 시 사용자 snapshot image 가 우선 선택되는가
- [ ] GitHub Actions 또는 로컬 Docker push 경로에서 `docker.io/edumgt/*` 이미지가 최신으로 올라가는가
- [ ] `/opt/k8s-data-platform/offline-bundle` 또는 `dist/offline-bundle` 에 image archive, wheels, npm cache, `k8s/infra`, `k8s/scripts`, `k8s/docs` 가 함께 존재하는가
- [ ] UFW / 보안 설정이 운영 포트만 허용하는가
