#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# NFS PVC Backup Script
#
# 備份所有 NFS-backed PVC 的資料到本地 backups/ 目錄。
# 備份前會 scale down 相關 workload 確保資料一致性，備份完成後 scale back up。
#
# Usage: ./scripts/backup-nfs-data.sh [--skip-scaledown]
#   --skip-scaledown  跳過 scale down（不建議，但在無法停服務時使用）
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077

SKIP_SCALEDOWN=false
for arg in "$@"; do
  case "$arg" in
    --skip-scaledown) SKIP_SCALEDOWN=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/../backups"
TIMESTAMP="$(date +%Y%m%d%H%M)"
BACKUP_SUBDIR="${BACKUP_DIR}/nfs-${TIMESTAMP}"

# ──────────────── Preflight ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1  || { echo "❌ Cannot reach cluster"; exit 1; }

echo "🗂️  NFS PVC Backup"
echo "   Target: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"

# ──────────────── Helper: archive a pod path to local .tar.gz ────────────────
backup_pod_path() {
  local ns="$1" pod="$2" container_path="$3" outfile="$4"
  echo "   📦 ${ns}/${pod}:${container_path} → ${outfile}"
  kubectl exec -n "${ns}" "${pod}" -- \
    tar czf - --directory="${container_path}" . 2>/dev/null \
    > "${BACKUP_SUBDIR}/${outfile}"
  local size
  size=$(du -sh "${BACKUP_SUBDIR}/${outfile}" | cut -f1)
  echo "      ✅ ${size}"
}

# ──────────────── Scale down ────────────────
if [ "${SKIP_SCALEDOWN}" = "false" ]; then
  echo ""
  echo "⬇️  Scaling down workloads..."
  kubectl scale deployment n8n-main         -n n8n        --replicas=0 2>/dev/null && echo "   ✅ n8n-main"        || echo "   ⚠️  n8n-main not found, skipping"
  kubectl scale deployment obs-grafana      -n monitoring --replicas=0 2>/dev/null && echo "   ✅ obs-grafana"     || echo "   ⚠️  obs-grafana not found, skipping"
  kubectl scale statefulset prometheus-obs-prometheus     -n monitoring --replicas=0 2>/dev/null && echo "   ✅ prometheus"     || echo "   ⚠️  prometheus not found, skipping"
  kubectl scale statefulset alertmanager-obs-alertmanager -n monitoring --replicas=0 2>/dev/null && echo "   ✅ alertmanager"   || echo "   ⚠️  alertmanager not found, skipping"
  echo "   ⏳ Waiting for pods to terminate..."
  kubectl wait --for=delete pod -n n8n        -l app.kubernetes.io/name=n8n       --timeout=120s 2>/dev/null || true
  kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=grafana   --timeout=120s 2>/dev/null || true
  kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=prometheus --timeout=120s 2>/dev/null || true
  kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=alertmanager --timeout=120s 2>/dev/null || true
  echo "   ✅ All targeted pods terminated"
fi

# ──────────────── Backup via temp pods (PVC already unmounted) ────────────────
echo ""
echo "💾 Backing up PVC data via temporary pods..."

run_backup_job() {
  local ns="$1" pvc_name="$2" mount_path="$3" outfile="$4" image="${5:-docker.io/library/busybox:1.36}"
  local job_name="nfs-backup-$(echo "${pvc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-40)"

  echo "   📦 ${ns}/${pvc_name} → ${outfile}"

  # Create a one-shot pod
  kubectl run "${job_name}" -n "${ns}" --restart=Never --rm=false \
    --image="${image}" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"backup\",
          \"image\": \"${image}\",
          \"command\": [\"sh\",\"-c\",\"tar czf - --directory=${mount_path} . && echo DONE\"],
          \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"${mount_path}\"}]
        }],
        \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}],
        \"restartPolicy\": \"Never\"
      }
    }" 2>/dev/null

  # Wait for pod to complete
  kubectl wait pod "${job_name}" -n "${ns}" --for=condition=Ready --timeout=60s 2>/dev/null || \
  kubectl wait pod "${job_name}" -n "${ns}" --for=jsonpath='{.status.phase}'=Running --timeout=60s 2>/dev/null || true

  # Collect output
  kubectl logs -n "${ns}" "${job_name}" --follow=false 2>/dev/null \
    > "${BACKUP_SUBDIR}/${outfile}" || true

  local size
  size=$(du -sh "${BACKUP_SUBDIR}/${outfile}" 2>/dev/null | cut -f1 || echo "?")
  echo "      ✅ ${size}"

  kubectl delete pod "${job_name}" -n "${ns}" --ignore-not-found=true 2>/dev/null || true
}

# Use direct exec if pods are still running (--skip-scaledown), else temp pod
if [ "${SKIP_SCALEDOWN}" = "true" ]; then
  N8N_POD=$(kubectl get pod -n n8n -l app.kubernetes.io/name=n8n \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  [ -n "${N8N_POD}" ]    && backup_pod_path n8n        "${N8N_POD}"     /home/node/.n8n  n8n.tar.gz
  [ -n "${GRAFANA_POD}" ] && backup_pod_path monitoring "${GRAFANA_POD}" /var/lib/grafana grafana.tar.gz

  PROM_POD="prometheus-obs-prometheus-0"
  AM_POD="alertmanager-obs-alertmanager-0"
  kubectl get pod "${PROM_POD}" -n monitoring &>/dev/null && \
    backup_pod_path monitoring "${PROM_POD}" /prometheus  prometheus.tar.gz
  kubectl get pod "${AM_POD}" -n monitoring &>/dev/null && \
    backup_pod_path monitoring "${AM_POD}"   /alertmanager alertmanager.tar.gz
else
  run_backup_job n8n        "n8n-data"                                              "/home/node/.n8n"  "n8n.tar.gz"
  run_backup_job monitoring "grafana-data"                                          "/var/lib/grafana" "grafana.tar.gz"
  run_backup_job monitoring "prometheus-data-prometheus-obs-prometheus-0"           "/prometheus"      "prometheus.tar.gz"
  run_backup_job monitoring "alertmanager-data-alertmanager-obs-alertmanager-0"     "/alertmanager"    "alertmanager.tar.gz"
fi

# ──────────────── Scale back up ────────────────
if [ "${SKIP_SCALEDOWN}" = "false" ]; then
  echo ""
  echo "⬆️  Scaling workloads back up..."
  kubectl scale deployment n8n-main         -n n8n        --replicas=1 2>/dev/null && echo "   ✅ n8n-main"        || true
  kubectl scale deployment obs-grafana      -n monitoring --replicas=1 2>/dev/null && echo "   ✅ obs-grafana"     || true
  kubectl scale statefulset prometheus-obs-prometheus     -n monitoring --replicas=1 2>/dev/null && echo "   ✅ prometheus"     || true
  kubectl scale statefulset alertmanager-obs-alertmanager -n monitoring --replicas=1 2>/dev/null && echo "   ✅ alertmanager"   || true
fi

# ──────────────── Summary ────────────────
echo ""
echo "✅ Backup complete: ${BACKUP_SUBDIR}"
echo ""
ls -lh "${BACKUP_SUBDIR}"
echo ""
echo "📋 To restore after NFS migration, run:"
echo "   ./scripts/restore-nfs-data.sh ${BACKUP_SUBDIR}"
