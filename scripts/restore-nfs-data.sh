#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# NFS PVC Restore Script
#
# 將 backup-nfs-data.sh 產生的備份還原到新建立的 NFS PVCs。
# 在 NFS backing volume 遷移到 XFS 之後執行此腳本。
#
# Usage: ./scripts/restore-nfs-data.sh <backup-dir>
#   backup-dir  由 backup-nfs-data.sh 建立的備份目錄 (e.g. backups/nfs-202604131400/)
#
# Prerequisites（執行前需確認）:
#   - NFS provisioner 已重建（oci-bv-xfs + --enable-xfs-quota）
#   - 所有 PVC 已由 terraform apply 或 StatefulSet 重建
#   - 所有目標 workload 已 scale down
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BACKUP_DIR="${1:-}"
if [ -z "${BACKUP_DIR}" ] || [ ! -d "${BACKUP_DIR}" ]; then
  echo "❌ Usage: $0 <backup-dir>"
  echo "   Example: $0 backups/nfs-202604131400"
  exit 1
fi

BACKUP_DIR="$(cd "${BACKUP_DIR}" && pwd)"

# ──────────────── Preflight ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "❌ Cannot reach cluster"; exit 1; }

echo "♻️  NFS PVC Restore"
echo "   Source: ${BACKUP_DIR}"
echo ""

# ──────────────── Verify NFS provisioner is ready ────────────────
echo "🔍 Verifying NFS provisioner is ready..."
if ! kubectl get storageclass nfs >/dev/null 2>&1; then
  echo "❌ StorageClass 'nfs' not found. Run 'terraform apply' first."
  exit 1
fi
NFS_POD=$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${NFS_POD}" ]; then
  echo "❌ nfs-server-provisioner Pod not found. Run 'terraform apply' first."
  exit 1
fi
echo "   ✅ NFS provisioner: ${NFS_POD}"

# ──────────────── Scale down workloads ────────────────
echo ""
echo "⬇️  Scaling down workloads before restore..."
kubectl scale deployment n8n-main         -n n8n        --replicas=0 2>/dev/null && echo "   ✅ n8n-main"        || echo "   ⚠️  n8n-main not found, skipping"
kubectl scale deployment obs-grafana      -n monitoring --replicas=0 2>/dev/null && echo "   ✅ obs-grafana"     || echo "   ⚠️  obs-grafana not found, skipping"
kubectl scale statefulset prometheus-obs-prometheus     -n monitoring --replicas=0 2>/dev/null && echo "   ✅ prometheus"     || echo "   ⚠️  prometheus not found, skipping"
kubectl scale statefulset alertmanager-obs-alertmanager -n monitoring --replicas=0 2>/dev/null && echo "   ✅ alertmanager"   || echo "   ⚠️  alertmanager not found, skipping"
echo "   ⏳ Waiting for pods to terminate..."
kubectl wait --for=delete pod -n n8n        -l app.kubernetes.io/name=n8n          --timeout=120s 2>/dev/null || true
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=grafana      --timeout=120s 2>/dev/null || true
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=prometheus   --timeout=120s 2>/dev/null || true
kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=alertmanager --timeout=120s 2>/dev/null || true

# ──────────────── Helper: restore archive into a PVC via temp pod ────────────────
restore_pvc() {
  local ns="$1" pvc_name="$2" mount_path="$3" archive="$4"
  local image="docker.io/library/busybox:1.36"
  local pod_name="nfs-restore-$(echo "${pvc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)"

  if [ ! -f "${archive}" ]; then
    echo "   ⚠️  Archive not found: ${archive}, skipping ${pvc_name}"
    return
  fi

  # Verify PVC exists
  if ! kubectl get pvc "${pvc_name}" -n "${ns}" >/dev/null 2>&1; then
    echo "   ❌ PVC ${ns}/${pvc_name} not found — was terraform apply run?"
    return 1
  fi

  echo "   ♻️  ${archive} → ${ns}/${pvc_name}:${mount_path}"

  # Create temp pod
  kubectl run "${pod_name}" -n "${ns}" --restart=Never --rm=false \
    --image="${image}" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"restore\",
          \"image\": \"${image}\",
          \"command\": [\"sh\",\"-c\",\"tar xzf - --directory=${mount_path} && echo RESTORE_DONE\"],
          \"stdin\": true,
          \"stdinOnce\": true,
          \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"${mount_path}\"}]
        }],
        \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}],
        \"restartPolicy\": \"Never\"
      }
    }" 2>/dev/null

  # Wait for pod to be ready to accept stdin
  kubectl wait pod "${pod_name}" -n "${ns}" --for=condition=Ready --timeout=90s 2>/dev/null || \
  kubectl wait pod "${pod_name}" -n "${ns}" --for=jsonpath='{.status.phase}'=Running --timeout=90s 2>/dev/null || true

  # Stream archive into pod stdin
  kubectl exec -i -n "${ns}" "${pod_name}" -- sh -c "tar xzf - --directory=${mount_path}" \
    < "${archive}"

  # Wait for completion
  kubectl wait pod "${pod_name}" -n "${ns}" \
    --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null || true

  kubectl delete pod "${pod_name}" -n "${ns}" --ignore-not-found=true 2>/dev/null || true
  echo "      ✅ Done"
}

# ──────────────── StatefulSet PVC readiness: trigger pod creation then scale down ────────────────
# StatefulSet PVCs are only created when the StatefulSet starts a pod.
# We start them briefly, wait for PVC binding, then scale down before restoring.
ensure_statefulset_pvcs() {
  local sts_name="$1" ns="$2"
  local pvc_pattern="$3"

  if kubectl get pvc -n "${ns}" | grep -q "${pvc_pattern}"; then
    echo "   ✅ PVC already exists for ${sts_name}"
    return
  fi

  echo "   ⏳ Starting ${sts_name} briefly to create PVCs..."
  kubectl scale statefulset "${sts_name}" -n "${ns}" --replicas=1 2>/dev/null || true
  kubectl wait --for=jsonpath='{.status.readyReplicas}'=1 statefulset "${sts_name}" \
    -n "${ns}" --timeout=180s 2>/dev/null || \
  sleep 30  # fallback: just wait 30s for PVC to be created
  kubectl scale statefulset "${sts_name}" -n "${ns}" --replicas=0 2>/dev/null || true
  kubectl wait --for=delete pod -n "${ns}" -l "app.kubernetes.io/name=${sts_name}" \
    --timeout=120s 2>/dev/null || true
}

echo ""
echo "🔧 Ensuring StatefulSet PVCs exist..."
ensure_statefulset_pvcs "prometheus-obs-prometheus"     "monitoring" "prometheus-data-prometheus-obs-prometheus-0"
ensure_statefulset_pvcs "alertmanager-obs-alertmanager" "monitoring" "alertmanager-data-alertmanager-obs-alertmanager-0"

# ──────────────── Restore ────────────────
echo ""
echo "♻️  Restoring data..."

restore_pvc "n8n"        "n8n-data"                                          "/home/node/.n8n"  "${BACKUP_DIR}/n8n.tar.gz"
restore_pvc "monitoring" "grafana-data"                                      "/var/lib/grafana" "${BACKUP_DIR}/grafana.tar.gz"
restore_pvc "monitoring" "prometheus-data-prometheus-obs-prometheus-0"       "/prometheus"      "${BACKUP_DIR}/prometheus.tar.gz"
restore_pvc "monitoring" "alertmanager-data-alertmanager-obs-alertmanager-0" "/alertmanager"    "${BACKUP_DIR}/alertmanager.tar.gz"

# ──────────────── Scale back up ────────────────
echo ""
echo "⬆️  Scaling workloads back up..."
kubectl scale deployment n8n-main         -n n8n        --replicas=1 2>/dev/null && echo "   ✅ n8n-main"        || true
kubectl scale deployment obs-grafana      -n monitoring --replicas=1 2>/dev/null && echo "   ✅ obs-grafana"     || true
kubectl scale statefulset prometheus-obs-prometheus     -n monitoring --replicas=1 2>/dev/null && echo "   ✅ prometheus"     || true
kubectl scale statefulset alertmanager-obs-alertmanager -n monitoring --replicas=1 2>/dev/null && echo "   ✅ alertmanager"   || true

echo ""
echo "✅ Restore complete."
echo ""
echo "📋 Verify quotas after pods start:"
echo "   NFS_POD=\$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner -o jsonpath='{.items[0].metadata.name}')"
echo "   kubectl exec -n nfs-storage \"\${NFS_POD}\" -- xfs_quota -x -c 'report -h' /export"
