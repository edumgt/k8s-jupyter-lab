# TROUBLESHOOTING.md
## 장애 대응 가이드

## 1) Pod가 `Running`이 아닌 경우

```bash
bash scripts/status_k8s.sh --env dev
kubectl get pods -n data-platform-dev -o wide
kubectl describe pod <pod-name> -n data-platform-dev
kubectl logs <pod-name> -n data-platform-dev --previous
```

## 2) CoreDNS / CNI 문제
- 증상: `coredns`가 `Pending/Unknown/CrashLoopBackOff`
- 점검:

```bash
kubectl get pods -n kube-system
kubectl logs -n kube-flannel <flannel-pod-name> --previous
```

- 네트워크 sysctl 재적용(필요 시):

```bash
sudo modprobe br_netfilter || true
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
sudo sysctl -w net.ipv4.ip_forward=1
```

## 3) 서비스 접속 실패
- NodePort 확인:

```bash
kubectl get svc -n data-platform-dev
```

- 로컬 VM 내부 점검:

```bash
curl -I http://127.0.0.1:30080/
curl -I http://127.0.0.1:30081/docs
```

## 4) 재배포

```bash
bash scripts/svc-down.sh --env dev --delete-namespace
bash scripts/svc-up.sh --env dev
```

## 5) 백업 복구

```bash
bash scripts/backup_platform.sh --env dev
bash scripts/restore_platform.sh --env dev --backup-dir <backup-dir>
```

