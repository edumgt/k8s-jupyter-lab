# VMware 운영 가이드

## 1) VM/OVA 빌드

```bash
bash scripts/build_vmware_ova_and_verify.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl
```

## 2) OVA Export

```bash
bash ovabuild.sh --vars-file packer/variables.vmware.auto.pkrvars.hcl --dist-dir C:/ffmpeg
```

## 3) 폐쇄망 설치

```bash
bash scripts/phase3_install_from_completed_ova.sh full
```

## 4) 점검

```bash
bash scripts/status_k8s.sh
bash scripts/check_vm_airgap_status.sh
```
