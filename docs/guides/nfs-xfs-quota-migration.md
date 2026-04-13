# NFS XFS Project Quota Migration

## 背景

`nfs-server-provisioner` 的 backing volume 原先使用 `oci-bv` StorageClass（ext4 格式）。
ext4 無法支援 XFS project quotas，導致所有 NFS PVC 沒有真實的 storage 上限：

- Pod 可以寫超過 `requests.storage` 指定的容量
- `kubelet_volume_stats_used_bytes` 對所有 NFS PVC 回傳相同值（NFS filesystem 總用量）
- Dashboard 的 "FS Used %" 無法反映 per-PVC 實際使用狀況

本次遷移目標：

1. 以 XFS 格式的 backing volume 重建 NFS provisioner
2. 啟用 `--enable-xfs-quota`，讓每個 PVC 的目錄受到 XFS project quota 限制
3. 完整備份與還原所有 NFS PVC 資料

---

## 遷移前確認

```bash
# 確認備份工具就緒
command -v kubectl && kubectl cluster-info

# 確認當前 PVC 狀態
kubectl get pvc -A | grep nfs
```

---

## Phase 0：備份所有 NFS PVC 資料

```bash
./scripts/backup-nfs-data.sh
```

腳本會自動：

1. Scale down：n8n、grafana、prometheus、alertmanager
2. 使用 temp Pod + tar 備份各 PVC 資料至 `backups/nfs-<timestamp>/`
3. Scale back up

備份後確認：

```bash
ls -lh backups/nfs-<timestamp>/
# 應看到：n8n.tar.gz, grafana.tar.gz, prometheus.tar.gz, alertmanager.tar.gz
```

> ⚠️ **請確保 `backups/` 目錄已備份到安全位置再繼續。**

---

## Phase 1：Scale Down 所有 NFS Workloads

確保沒有 Pod 正在寫入 NFS PVC：

```bash
kubectl scale deployment n8n-main    -n n8n        --replicas=0
kubectl scale deployment obs-grafana -n monitoring --replicas=0

# Prometheus/Alertmanager 由 Operator 管理，直接 scale StatefulSet 無效，
# operator 會立刻把 pod 補回來。需 patch CR 讓 operator 自己縮放。
kubectl patch prometheus   obs-prometheus   -n monitoring -p '{"spec":{"replicas":0}}' --type=merge
kubectl patch alertmanager obs-alertmanager -n monitoring -p '{"spec":{"replicas":0}}' --type=merge

# 等待全部 terminate
kubectl wait --for=delete pod -n n8n        -l app.kubernetes.io/name=n8n     --timeout=120s
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=grafana --timeout=120s
# Prometheus 預設 terminationGracePeriodSeconds=600s；若仍卡住就 force delete
for pod in prometheus-obs-prometheus-0 alertmanager-obs-alertmanager-0; do
  kubectl wait --for=delete "pod/${pod}" -n monitoring --timeout=660s 2>/dev/null || \
    kubectl delete pod "${pod}" -n monitoring --grace-period=0 --force
done
```

---

## Phase 2：刪除 NFS Helm Release 與 Backing PVC

> ⚠️ 此步驟會刪除 NFS 的所有資料。請確認 Phase 0 備份已完成。

```bash
# 刪除 Helm release（不刪除 namespace）
helm uninstall nfs-server-provisioner -n nfs-storage

# 刪除 NFS PVC 和其下的所有子目錄 PVCs
# （StatefulSet PVCs 在 workload scale down 後仍存在，需手動刪除）
kubectl delete pvc -n monitoring \
  alertmanager-data-alertmanager-obs-alertmanager-0 \
  grafana-data \
  prometheus-data-prometheus-obs-prometheus-0

kubectl delete pvc -n n8n n8n-data

# 刪除 NFS backing PVC（這會觸發 OCI block volume 刪除）
kubectl delete pvc data-nfs-server-provisioner-0 -n nfs-storage

# 確認 PVC 都已刪除
kubectl get pvc -A
```

---

## Phase 3：Terraform Apply（重建 XFS 版本）

```bash
terraform apply
```

Terraform 會：

1. 建立 StorageClass `oci-bv-xfs`（`blockvolume.csi.oraclecloud.com` + `fstype=xfs`）
2. 重建 `nfs-server-provisioner`，使用 `oci-bv-xfs` + `--enable-xfs-quota`
3. 重建 Terraform-managed PVCs（`n8n-data`、`grafana-data`）

等待 NFS provisioner 就緒：

```bash
kubectl wait pod -n nfs-storage \
  -l app=nfs-server-provisioner \
  --for=condition=Ready --timeout=300s
```

確認 XFS quota 已啟用：

```bash
NFS_POD=$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner \
  -o jsonpath='{.items[0].metadata.name}')

# 確認 /export 是 XFS 格式
kubectl exec -n nfs-storage "${NFS_POD}" -- df -T /export

# 確認 prjquota mount option
kubectl exec -n nfs-storage "${NFS_POD}" -- mount | grep /export
```

---

## Phase 4：還原資料

```bash
./scripts/restore-nfs-data.sh backups/nfs-<timestamp>
```

腳本會自動：

1. Scale down workloads（確保 PVC 不被寫入）
2. 觸發 StatefulSet 短暫啟動以建立 PVC，再立即 scale down
3. 用 temp Pod + tar 將資料還原至各 PVC
4. Scale back up

---

## Phase 5：驗證

### 確認服務正常

```bash
kubectl get pod -A | grep -E "n8n|monitoring"
kubectl get pvc -A
```

### 確認 XFS Quota 生效

```bash
NFS_POD=$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner \
  -o jsonpath='{.items[0].metadata.name}')

# 查看所有 project quota（應看到每個 PVC 對應的 quota 條目）
kubectl exec -n nfs-storage "${NFS_POD}" -- xfs_quota -x -c 'report -h' /export
```

預期輸出範例：

```
Project quota on /export (blockvolume.csi.oraclecloud.com)
                        Blocks
Project ID   Used   Soft   Hard Warn/Grace
---------- ---------------------------------
#0              0      0      0  00 [------]
#1          7.4M      0      5G  00 [------]   ← n8n-data (5 GiB limit)
#2         51.3M      0      5G  00 [------]   ← grafana-data (5 GiB limit)
...
```

### 確認 Dashboard

在 Grafana → OKE Cluster Overview → Volume Usage 面板：

- "Used" 欄每個 PVC 應顯示**不同值**（不再全是同一個數字）
- "FS Used %" 應反映各 PVC 實際使用率

---

## Rollback

如果遷移失敗，可以從備份還原舊的 ext4 NFS：

1. 恢復原本的 `main.tf`（移除 `oci-bv-xfs` StorageClass 和 `server.args`）
2. `terraform apply`
3. `./scripts/restore-nfs-data.sh backups/nfs-<timestamp>`
