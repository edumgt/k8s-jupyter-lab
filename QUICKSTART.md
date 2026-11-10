# QUICKSTART.md

## 로컬 원라이너 (OVA 불필요)

```bash
bash scripts/quickstart_airgap_mock.sh
```

`docker-compose.airgap-mock.yml`로 같은 포트를 로컬에서 재현합니다. 폐쇄망 OVA 설치를 대체하지 않습니다. 첫 실행은 이미지 pull/빌드용 네트워크가 필요합니다.

- Frontend: `http://127.0.0.1:30080`
- Backend API docs: `http://127.0.0.1:30081/docs`
- Jupyter: `http://127.0.0.1:30088/lab?token=platform123`
- GitLab mock: `http://127.0.0.1:30089`
- Airflow mock: `http://127.0.0.1:30090`
- Nexus mock: `http://127.0.0.1:30091`
- Harbor mock: `http://127.0.0.1:30083`
- 데모 로그인: `admin@test.com` / `123456`

종료:

```bash
bash scripts/quickstart_airgap_mock.sh down
```

Compose만 쓰려면:

```bash
docker compose -f docker-compose.airgap-mock.yml up -d --build
```

## 클러스터 빠른 시작 (Kubernetes)

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

