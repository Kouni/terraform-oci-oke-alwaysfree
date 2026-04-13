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

IMAGE="docker.io/library/busybox:1.36"

# ──────────────── Preflight ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "❌ Cannot reach cluster"; exit 1; }

echo "🗂️  NFS PVC Backup"
echo "   Target: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"

# ──────────────── Helper: exec tar from a running pod (binary-safe) ────────────────
backup_from_running_pod() {
  local ns="$1" pod="$2" container_path="$3" outfile="$4"
  echo "   📦 ${ns}/${pod}:${container_path} → ${outfile}"
  kubectl exec -n "${ns}" "${pod}" -- \
    tar czf - --directory="${container_path}" . \
    > "${BACKUP_SUBDIR}/${outfile}"
  local size
  size=$(du -sh "${BACKUP_SUBDIR}/${outfile}" | cut -f1)
  echo "      ✅ ${size}"
}

# ──────────────── Helper: backup a PVC via a temp sleeping pod (binary-safe) ────────────────
# The pod sleeps; we exec tar and pipe its stdout to a local file.
# kubectl logs is NOT used — it corrupts binary (gzip) data.
backup_pvc() {
  local ns="$1" pvc_name="$2" mount_path="$3" outfile="$4"
  local pod_name
  pod_name="nfs-bkp-$(echo "${pvc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-36)"

  echo "   📦 ${ns}/${pvc_name} → ${outfile}"

  kubectl run "${pod_name}" -n "${ns}" --restart=Never --rm=false \
    --image="${IMAGE}" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"backup\",
          \"image\": \"${IMAGE}\",
          \"command\": [\"sh\", \"-c\", \"sleep 3600\"],
          \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"${mount_path}\"}]
        }],
        \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}],
        \"restartPolicy\": \"Never\"
      }
    }" >/dev/null 2>&1

  kubectl wait pod "${pod_name}" -n "${ns}" --for=condition=Ready --timeout=120s >/dev/null

  # Stream tar directly via exec — binary-safe
  kubectl exec -n "${ns}" "${pod_name}" -- \
    tar czf - --directory="${mount_path}" . \
    > "${BACKUP_SUBDIR}/${outfile}"

  local size
  size=$(du -sh "${BACKUP_SUBDIR}/${outfile}" | cut -f1)
  echo "      ✅ ${size}"

  kubectl delete pod "${pod_name}" -n "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true
}

# ──────────────── Scale down ────────────────
if [ "${SKIP_SCALEDOWN}" = "false" ]; then
  echo ""
  echo "⬇️  Scaling down workloads..."
  kubectl scale deployment n8n-main    -n n8n        --replicas=0 2>/dev/null && echo "   ✅ n8n-main"    || echo "   ⚠️  n8n-main not found"
  kubectl scale deployment obs-grafana -n monitoring --replicas=0 2>/dev/null && echo "   ✅ obs-grafana" || echo "   ⚠️  obs-grafana not found"
  # Prometheus/Alertmanager are managed by the Operator — patch the CR, not the StatefulSet.
  # Scaling the StatefulSet directly is overridden by the operator immediately.
  kubectl patch prometheus    obs-prometheus    -n monitoring -p '{"spec":{"replicas":0}}' --type=merge 2>/dev/null && echo "   ✅ prometheus"   || echo "   ⚠️  prometheus CR not found"
  kubectl patch alertmanager  obs-alertmanager  -n monitoring -p '{"spec":{"replicas":0}}' --type=merge 2>/dev/null && echo "   ✅ alertmanager" || echo "   ⚠️  alertmanager CR not found"
  echo "   ⏳ Waiting for pods to terminate..."
  kubectl wait --for=delete pod -n n8n        -l app.kubernetes.io/name=n8n     --timeout=120s 2>/dev/null || true
  kubectl wait --for=delete pod -n monitoring -l app.kubernetes.io/name=grafana --timeout=120s 2>/dev/null || true
  for pod in prometheus-obs-prometheus-0 alertmanager-obs-alertmanager-0; do
    if kubectl get pod "${pod}" -n monitoring >/dev/null 2>&1; then
      kubectl wait --for=delete "pod/${pod}" -n monitoring --timeout=660s 2>/dev/null || {
        echo "   ⚠️  ${pod} stuck in Terminating — force deleting"
        kubectl delete pod "${pod}" -n monitoring --grace-period=0 --force 2>/dev/null || true
        kubectl wait --for=delete "pod/${pod}" -n monitoring --timeout=60s 2>/dev/null || true
      }
    fi
  done
  echo "   ✅ All targeted pods terminated"
fi

# ──────────────── Backup ────────────────
echo ""
echo "💾 Backing up PVC data..."

if [ "${SKIP_SCALEDOWN}" = "true" ]; then
  N8N_POD=$(kubectl get pod -n n8n -l app.kubernetes.io/name=n8n \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  GRAFANA_POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  PROM_POD="prometheus-obs-prometheus-0"
  AM_POD="alertmanager-obs-alertmanager-0"

  [ -n "${N8N_POD}" ]     && backup_from_running_pod n8n        "${N8N_POD}"     /home/node/.n8n  n8n.tar.gz
  [ -n "${GRAFANA_POD}" ] && backup_from_running_pod monitoring "${GRAFANA_POD}" /var/lib/grafana grafana.tar.gz
  kubectl get pod "${PROM_POD}" -n monitoring >/dev/null 2>&1 && \
    backup_from_running_pod monitoring "${PROM_POD}" /prometheus  prometheus.tar.gz
  kubectl get pod "${AM_POD}"  -n monitoring >/dev/null 2>&1 && \
    backup_from_running_pod monitoring "${AM_POD}"   /alertmanager alertmanager.tar.gz
else
  backup_pvc n8n        "n8n-data"                                              "/home/node/.n8n"  "n8n.tar.gz"
  backup_pvc monitoring "grafana-data"                                          "/var/lib/grafana" "grafana.tar.gz"
  backup_pvc monitoring "prometheus-data-prometheus-obs-prometheus-0"           "/prometheus"      "prometheus.tar.gz"
  backup_pvc monitoring "alertmanager-data-alertmanager-obs-alertmanager-0"     "/alertmanager"    "alertmanager.tar.gz"
fi

# ──────────────── Scale back up ────────────────
if [ "${SKIP_SCALEDOWN}" = "false" ]; then
  echo ""
  echo "⬆️  Scaling workloads back up..."
  kubectl scale deployment n8n-main    -n n8n        --replicas=1 2>/dev/null && echo "   ✅ n8n-main"    || true
  kubectl scale deployment obs-grafana -n monitoring --replicas=1 2>/dev/null && echo "   ✅ obs-grafana" || true
  kubectl patch prometheus   obs-prometheus   -n monitoring -p '{"spec":{"replicas":1}}' --type=merge 2>/dev/null && echo "   ✅ prometheus"   || true
  kubectl patch alertmanager obs-alertmanager -n monitoring -p '{"spec":{"replicas":1}}' --type=merge 2>/dev/null && echo "   ✅ alertmanager" || true
fi

# ──────────────── Summary ────────────────
echo ""
echo "✅ Backup complete: ${BACKUP_SUBDIR}"
echo ""
ls -lh "${BACKUP_SUBDIR}"
echo ""
echo "📋 To restore after NFS migration, run:"
echo "   ./scripts/restore-nfs-data.sh ${BACKUP_SUBDIR}"
