# `bh` Bastion VM 구성 가이드 (VMware 연습용)

목표:

- VMware에 `bh`라는 bastion VM 1대를 만들고
- `edumgt` 계정으로 SSH/pdsh 기반 운영 연습 환경을 준비

사무실 서버 맵 기준값은 `docs/edumgt-office-server-map.md`를 참고하세요.

## 1) 자동 생성 스크립트

추가된 스크립트:

- `scripts/vmware_create_bastion_bh.sh`

이 스크립트는 다음을 자동 수행합니다.

1. 기존 Ubuntu VMX를 source로 `bh` VM clone
2. VM 부팅 및 guest IP 확인
3. guest 내 `edumgt` 생성 + passwordless sudo
4. `pdsh`, `openssh-client`, `sshpass` 설치
5. (옵션) static IP 설정
6. (옵션) pdsh 그룹 파일 생성

## 2) 실행 예시

```bash
cd /home/edumgt/edumgt-support/k8s-dev

# 템플릿 불러오기(값 수정 필수)
source scripts/templates/bh-bastion.env.example

bash scripts/vmware_create_bastion_bh.sh \
  --vars-file "${PACKER_VARS}" \
  --bastion-name "${BASTION_NAME}" \
  --ssh-user "${SSH_USER}" \
  --ssh-password "${SSH_PASSWORD}" \
  --ssh-port "${SSH_PORT}" \
  --edumgt-password "${EDUMGT_PASSWORD}" \
  --pdsh-group-hosts "${PDSH_GROUP_HOSTS}" \
  --static-network \
  --static-ip "${STATIC_IP}" \
  --gateway "${GATEWAY}" \
  --dns-servers "${DNS_SERVERS}" \
  --network-cidr-prefix "${NETWORK_CIDR_PREFIX}"
```

## 3) 접속 확인

```bash
# 내 PC/WSL -> bh
ssh edumgt@<YOUR_BASTION_INTERNAL_IP>

# bh -> k8s nodes (예시)
pdsh -R ssh -w <YOUR_MASTER_IP>,<YOUR_WORKER1_IP>,<YOUR_WORKER2_IP>,<YOUR_WORKER_ML1_IP> "hostname -I"
```

## 4) 운영 팁

- 바스천이 반입 대상이 아니면, 반입 전에는 운영 가이드 문서로만 유지합니다.
- 반입 후에는 같은 절차를 NAT 바깥 bastion 없이 내부 Jump host 기준으로 치환하면 됩니다.
- 노드 추가/삭제는 `docs/edumgt-office-vmware-practice.md`의 운영 절차를 그대로 사용하세요.
