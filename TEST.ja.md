# Kubernetes テストスナップショット（2026-03-19）

🌐 [English](TEST.en.md) | [中文](TEST.zh.md) | **日本語** | [한국어](TEST.md)

## 1) 現在の VM とノード IP サマリー

| VM 名 | Kubernetes ノード | 役割 | 状態 | 内部 IP |
|---|---|---|---|---|
| k8s-data-platform | k8s-data-platform | control-plane | 実行中 / Ready | 10.77.0.4 |
| k8s-worker-1 | k8s-worker-1 | worker | 実行中 / Ready | 10.77.0.5 |
| k8s-worker-2 | k8s-worker-2 | worker | 実行中 / Ready | 10.77.0.6 |
| k8s-worker-3 | 削除済み | worker | 停止中 | 10.77.0.7（旧） |

実行中の VM（`VBoxManage list runningvms`）：
- k8s-data-platform
- k8s-worker-1
- k8s-worker-2

現在の Kubernetes ノード（`kubectl get nodes -o wide`）：
- k8s-data-platform (10.77.0.4)
- k8s-worker-1 (10.77.0.5)
- k8s-worker-2 (10.77.0.6)

---

## 2) サービス IP と NodePort サマリー（`data-platform-dev`）

| サービス | タイプ | ClusterIP | サービスポート | NodePort | アクセス例 |
|---|---|---|---|---|---|
| airflow | NodePort | 10.99.64.233 | 8080/TCP | 30090 | `http://10.77.0.5:30090` |
| backend | NodePort | 10.108.80.33 | 8000/TCP | 30081 | `http://10.77.0.5:30081` |
| frontend | NodePort | 10.101.40.171 | 80/TCP | 30080 | `http://10.77.0.5:30080` |
| gitlab-web | NodePort | 10.102.234.133 | 8929/TCP, 22/TCP | 30089, 30224 | `http://10.77.0.5:30089`、`ssh -p 30224 ...` |
| jupyter | NodePort | 10.99.190.56 | 8888/TCP | 30088 | `http://10.77.0.5:30088` |
| nexus | NodePort | 10.98.114.37 | 8081/TCP | 30091 | `http://10.77.0.5:30091` |
| mongodb | ClusterIP | 10.106.245.2 | 27017/TCP | なし | 内部のみ |
| redis | ClusterIP | 10.96.125.129 | 6379/TCP | なし | 内部のみ |

### 2.1 Windows ブラウザアクセス（frontend NodePort 30080）

重要：
- `10.101.40.171` は Kubernetes `ClusterIP` のため、Windows ブラウザから直接開けません。
- `ノード IP + NodePort` を使用してください：`http://10.77.0.5:30080`

Windows PowerShell で接続テスト：

```powershell
Test-NetConnection 10.77.0.5 -Port 30080
```

`TcpTestSucceeded = True` の場合：
- `http://10.77.0.5:30080` を開く

失敗する場合は VirtualBox NAT ポート転送を追加して localhost を使用：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "frontend:tcp:[127.0.0.1]:30080:[10.77.0.5]:30080"
```

その後：
- `http://127.0.0.1:30080`

### 2.2 Localhost モード（`127.0.0.1`）— 追加 NodePort 転送

`http://127.0.0.1:30080` で frontend にアクセスする場合：
- frontend ページは `30080` で読み込まれます
- frontend の API 呼び出しは backend `30081` に向かうため、backend の転送も必要です

最小限の追加転送：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "backend:tcp:[127.0.0.1]:30081:[10.77.0.5]:30081"
```

よく使う推奨転送ルール：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "jupyter:tcp:[127.0.0.1]:30088:[10.77.0.5]:30088"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "gitlab-web:tcp:[127.0.0.1]:30089:[10.77.0.5]:30089"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "airflow:tcp:[127.0.0.1]:30090:[10.77.0.5]:30090"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "nexus:tcp:[127.0.0.1]:30091:[10.77.0.5]:30091"
```

注意：
- 個人の JupyterLab セッションは動的に割り当てられた NodePort を使用します。
- localhost のみのアクセスを使用する場合は、frontend ステータスに表示された Jupyter NodePort に一時的な転送ルールを追加してください。

---

## 3) 適用済み SSH ルール

適用した NAT ネットワーク SSH 転送ルール：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-cp:tcp:[127.0.0.1]:2222:[10.77.0.4]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w1:tcp:[127.0.0.1]:2201:[10.77.0.5]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w2:tcp:[127.0.0.1]:2202:[10.77.0.6]:22"
```

Windows ホストの接続確認：
- `127.0.0.1:2222` = 開放
- `127.0.0.1:2201` = 開放
- `127.0.0.1:2202` = 開放

デフォルトアカウント/パスワード：
- ユーザー名：`ubuntu`
- パスワード：`ubuntu`

---

## 4) Windows および WSL からの SSH アクセス

### 4.1 Windows ターミナル

```bash
ssh ubuntu@127.0.0.1 -p 2222   # control-plane
ssh ubuntu@127.0.0.1 -p 2201   # worker-1
ssh ubuntu@127.0.0.1 -p 2202   # worker-2
```

### 4.2 WSL ターミナル（推奨、この環境で安定）

WSL から Windows OpenSSH クライアントを直接使用：

```bash
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2222
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2201
/mnt/c/Windows/System32/OpenSSH/ssh.exe ubuntu@127.0.0.1 -p 2202
```

理由：
- この環境では、WSL Linux ネイティブ `ssh` が WSL localhost 転送モードによっては転送済み localhost ポートへの接続に失敗する場合があります。
- Windows `ssh.exe` は常に Windows ネットワークスタックを使用するため、VBox 転送済みポートに安定して接続できます。

### 4.3 代替案（control-plane VM 内部から）

```bash
ssh ubuntu@10.77.0.5   # worker-1
ssh ubuntu@10.77.0.6   # worker-2
```

---

## 5) これらの VM を別の VirtualBox ホストに移行

推奨方法：OVA エクスポート/インポート。

### 5.1 ソースホスト（現在の PC）

1. VM をシャットダウン。
2. OVA ファイルをエクスポート：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-data-platform poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-1 poweroff
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" controlvm k8s-worker-2 poweroff

& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-data-platform --output C:\ffmpeg\k8s-data-platform.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-1 --output C:\ffmpeg\k8s-worker-1.ova
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" export k8s-worker-2 --output C:\ffmpeg\k8s-worker-2.ova
```

3. `.ova` ファイルをターゲット PC にコピー。

### 5.2 ターゲットホスト（別の VirtualBox PC）

OVA をインポート：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-data-platform.ova --vsys 0 --vmname k8s-data-platform
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-worker-1.ova --vsys 0 --vmname k8s-worker-1
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" import C:\ffmpeg\k8s-worker-2.ova --vsys 0 --vmname k8s-worker-2
```

---

## 6) インポート後のネットワーク設定（重要）

NAT ネットワークの作成（または更新）：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork add --netname k8s-data-platform-net --network 10.77.0.0/24 --dhcp on --enable
```

既に存在する場合：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --network 10.77.0.0/24 --dhcp on --enable
```

各 VM の NIC1 を NAT ネットワークに接続：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-data-platform --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-1 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm k8s-worker-2 --nic1 natnetwork --nat-network1 k8s-data-platform-net --cableconnected1 on
```

ターゲットホストで SSH 転送ルールを再適用：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-cp:tcp:[127.0.0.1]:2222:[10.77.0.4]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w1:tcp:[127.0.0.1]:2201:[10.77.0.5]:22"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" natnetwork modify --netname k8s-data-platform-net --port-forward-4 "ssh-w2:tcp:[127.0.0.1]:2202:[10.77.0.6]:22"
```

---

## 7) 起動と起動後チェック

起動順序：
1. control-plane（`k8s-data-platform`）
2. worker-1
3. worker-2

コマンド：

```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-data-platform --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-1 --type headless
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm k8s-worker-2 --type headless
```

control-plane 内部で：

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev -o wide
KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
```

古い `k8s-worker-3` ノードが表示された場合：

```bash
KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete node k8s-worker-3 --ignore-not-found
```

---

## 8) VMware インポート（設定と注意事項）

同じ OVA を VMware Workstation/Player にインポートする場合はこのセクションを参照。

### 8.1 推奨 VMware VM 設定

- vCPU：4 以上
- メモリ：16 GB 以上
- ディスク：100 GB 以上推奨
- ファームウェア：インポートした OVA のデフォルトを維持（起動失敗時のみ変更）
- ネットワークアダプター：ホストブラウザから NodePort への直接アクセスには `Bridged` 推奨

### 8.2 インポート手順（VMware）

1. VMware Workstation/Player を開く。
2. `k8s-data-platform.ova` をインポート/開く。
3. CPU/メモリ/ディスクを確認してインポートを完了。
4. VM を起動して以下でログイン：
   - ユーザー名：`ubuntu`
   - パスワード：`ubuntu`

### 8.3 起動後の初回確認

VM 内部で：

```bash
hostname -I
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n data-platform-dev -o wide
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get svc -n data-platform-dev
```

### 8.4 ホストブラウザアクセス（VMware）

VMware モードでは `VM_IP + NodePort` の直接アクセスを優先。

例：
- `http://<VM_IP>:30080`（frontend）
- `http://<VM_IP>:30081`（backend）
- `http://<VM_IP>:30088`（jupyter shared）
- `http://<VM_IP>:30089`（gitlab web）

### 8.5 重要な注意事項

- 本文書の VirtualBox NAT 転送コマンド（`VBoxManage natnetwork ... --port-forward-4`）は VMware には適用されません。
- `127.0.0.1:2222`、`2201`、`2202` の SSH 転送例は VirtualBox 専用です。
- VM 内部でファイアウォールが有効な場合、NodePort 範囲の許可が必要な場合があります：
  - `sudo ufw allow 30000:32767/tcp`
- `kubectl` が `localhost:8080` にフォールバックする場合は kubeconfig を強制指定：
  - `sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes`
- 本リポジトリのマルチノード自動ブートストラップスクリプトは VirtualBox 専用：
  - `scripts/bootstrap_virtualbox_multinode.ps1`
  - VMware マルチノードでは worker のクローン/参加/ネットワーク設定は手動です。

### 8.6 参照

- VMware 詳細ガイド：`docs/vmware/README.md`
