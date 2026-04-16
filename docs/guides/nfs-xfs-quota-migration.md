# NFS XFS Project Quota Migration

## Background

The `nfs-server-provisioner` backing volume originally used the `oci-bv` StorageClass (ext4 format).
ext4 does not support XFS project quotas, resulting in no real storage limits for any NFS PVC:

- Pods can write beyond the capacity specified in `requests.storage`
- `kubelet_volume_stats_used_bytes` returns the same value for all NFS PVCs (total NFS filesystem usage)
- The dashboard's "FS Used %" cannot reflect actual per-PVC usage

Migration objectives:

1. Rebuild the NFS provisioner with an XFS-formatted backing volume
2. Enable `--enable-xfs-quota` so that each PVC's directory is subject to XFS project quota limits
3. Fully back up and restore all NFS PVC data

---

## Pre-Migration Verification

```bash
# Verify backup tools are ready
command -v kubectl && kubectl cluster-info

# Check current PVC status
kubectl get pvc -A | grep nfs
```

---

## Phase 0: Back Up All NFS PVC Data

```bash
./scripts/backup-nfs-data.sh
```

The script will automatically:

1. Scale down: n8n
2. Use a temp Pod + tar to back up n8n PVC data to `backups/nfs-<timestamp>/`
3. Scale back up

Post-backup verification:

```bash
ls -lh backups/nfs-<timestamp>/
# Expected: n8n.tar.gz
```

> [!] **Ensure the `backups/` directory is backed up to a safe location before proceeding.**

---

## Phase 1: Scale Down All NFS Workloads

Ensure no Pods are writing to NFS PVCs:

```bash
kubectl scale deployment n8n-main -n n8n --replicas=0

# Wait for termination
kubectl wait --for=delete pod -n n8n -l app.kubernetes.io/name=n8n --timeout=120s
```

---

## Phase 2: Delete NFS Helm Release and Backing PVC

> [!] This step will delete all NFS data. Confirm that the Phase 0 backup is complete.

```bash
# Delete the Helm release (do not delete the namespace)
helm uninstall nfs-server-provisioner -n nfs-storage

# Delete NFS PVCs and all sub-directory PVCs
kubectl delete pvc -n n8n n8n-data

# Delete the NFS backing PVC (this triggers OCI block volume deletion)
kubectl delete pvc data-nfs-server-provisioner-0 -n nfs-storage

# Confirm all PVCs have been deleted
kubectl get pvc -A
```

---

## Phase 3: Terraform Apply (Rebuild with XFS)

```bash
terraform apply
```

Terraform will:

1. Create StorageClass `oci-bv-xfs` (`blockvolume.csi.oraclecloud.com` + `fstype=xfs`)
2. Rebuild `nfs-server-provisioner` using `oci-bv-xfs` + `--enable-xfs-quota`
3. Rebuild Terraform-managed PVCs (`n8n-data`)

Wait for the NFS provisioner to become ready:

```bash
kubectl wait pod -n nfs-storage \
  -l app=nfs-server-provisioner \
  --for=condition=Ready --timeout=300s
```

Verify that XFS quota is enabled:

```bash
NFS_POD=$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner \
  -o jsonpath='{.items[0].metadata.name}')

# Verify /export is XFS formatted
kubectl exec -n nfs-storage "${NFS_POD}" -- df -T /export

# Verify prjquota mount option
kubectl exec -n nfs-storage "${NFS_POD}" -- mount | grep /export
```

---

## Phase 4: Restore Data

```bash
./scripts/restore-nfs-data.sh backups/nfs-<timestamp>
```

The script will automatically:

1. Scale down n8n (ensure the PVC is not being written to)
2. Use a temp Pod + tar to restore data to the PVC
3. Scale back up

---

## Phase 5: Verification

### Confirm Services Are Running

```bash
kubectl get pod -n n8n
kubectl get pvc -A
```

### Confirm XFS Quota Is Active

```bash
NFS_POD=$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner \
  -o jsonpath='{.items[0].metadata.name}')

# View all project quotas (expect one quota entry per PVC)
kubectl exec -n nfs-storage "${NFS_POD}" -- xfs_quota -x -c 'report -h' /export
```

Expected output example:

```
Project quota on /export (blockvolume.csi.oraclecloud.com)
                        Blocks
Project ID   Used   Soft   Hard Warn/Grace
---------- ---------------------------------
#0              0      0      0  00 [------]
#1          7.4M      0      5G  00 [------]   ← n8n-data (5 GiB limit)
...
```

### Confirm kubelet Volume Metrics

```bash
# kubelet built-in volume stats can verify per-PVC used/capacity
kubectl get --raw "/api/v1/nodes/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')/proxy/stats/summary" | \
  jq '.pods[].volume[]? | select(.pvcRef != null) | {ns: .pvcRef.namespace, pvc: .pvcRef.name, used: .usedBytes, cap: .capacityBytes}'
```

---

## Rollback

If the migration fails, you can restore the old ext4 NFS from backup:

1. Revert `main.tf` to its original state (remove the `oci-bv-xfs` StorageClass and `server.args`)
2. `terraform apply`
3. `./scripts/restore-nfs-data.sh backups/nfs-<timestamp>`
