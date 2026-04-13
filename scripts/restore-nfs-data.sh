#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# NFS PVC Restore Script
#
# 將 backup-nfs-data.sh 產生的備份還原到新建立的 NFS PVCs。
# 在 NFS backing volume 遷移到 XFS 之後執行此腳本。
#
# Usage: ./scripts/restore-nfs-data.sh <backup-dir>
#   backup-dir  由 backup-nfs-data.sh 建立的備份目錄 (e.g. backups/nfs-202604131400)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BACKUP_DIR="${1:-}"
if [ -z "${BACKUP_DIR}" ] || [ ! -d "${BACKUP_DIR}" ]; then
  echo "❌ Usage: $0 <backup-dir>"
  echo "   Example: $0 backups/nfs-202604131400"
  exit 1
fi

BACKUP_DIR="$(cd "${BACKUP_DIR}" && pwd)"
IMAGE="docker.io/library/busybox:1.36"
ERRORS=0
WORKLOADS_SCALED_DOWN=false

# ──────────────── Scale-up is registered as an EXIT trap ────────────────
# This guarantees workloads are brought back up whether the script exits
# normally, via set -e, or due to an unhandled signal.
scale_up() {
  [ "${WORKLOADS_SCALED_DOWN}" = "true" ] || return 0
  echo ""
  echo "⬆️  Scaling workloads back up..."
  kubectl scale deployment n8n-main    -n n8n        --replicas=1 2>/dev/null && echo "   ✅ n8n-main"    || true
  kubectl scale deployment obs-grafana -n monitoring --replicas=1 2>/dev/null && echo "   ✅ obs-grafana" || true
  kubectl patch prometheus   obs-prometheus   -n monitoring -p '{"spec":{"replicas":1}}' --type=merge 2>/dev/null && echo "   ✅ prometheus"   || true
  kubectl patch alertmanager obs-alertmanager -n monitoring -p '{"spec":{"replicas":1}}' --type=merge 2>/dev/null && echo "   ✅ alertmanager" || true
}
trap scale_up EXIT

# ──────────────── Preflight ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "❌ Cannot reach cluster"; exit 1; }

echo "♻️  NFS PVC Restore"
echo "   Source: ${BACKUP_DIR}"
echo ""

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

# ──────────────── Cleanup leftover temp pods from previous runs ────────────────
echo ""
echo "🧹 Cleaning up any leftover temp pods..."
for ns in n8n monitoring; do
  leftover=$(kubectl get pod -n "${ns}" --no-headers 2>/dev/null \
    | awk '{print $1}' | grep -E "^nfs-rst-" || true)
  if [ -n "${leftover}" ]; then
    echo "${leftover}" | xargs kubectl delete pod -n "${ns}" \
      --ignore-not-found=true --grace-period=0 --force 2>/dev/null || true
    echo "   🗑️  Removed leftover pods in ${ns}"
  fi
done

# ──────────────── Scale down workloads ────────────────
echo ""
echo "⬇️  Scaling down workloads before restore..."
kubectl scale deployment n8n-main    -n n8n        --replicas=0 2>/dev/null && echo "   ✅ n8n-main"    || echo "   ⚠️  n8n-main not found"
kubectl scale deployment obs-grafana -n monitoring --replicas=0 2>/dev/null && echo "   ✅ obs-grafana" || echo "   ⚠️  obs-grafana not found"
# Prometheus/Alertmanager are managed by the Operator — patch the CR, not the StatefulSet.
kubectl patch prometheus   obs-prometheus   -n monitoring -p '{"spec":{"replicas":0}}' --type=merge 2>/dev/null && echo "   ✅ prometheus"   || echo "   ⚠️  prometheus CR not found"
kubectl patch alertmanager obs-alertmanager -n monitoring -p '{"spec":{"replicas":0}}' --type=merge 2>/dev/null && echo "   ✅ alertmanager" || echo "   ⚠️  alertmanager CR not found"
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
echo "   ✅ All workloads scaled down"
WORKLOADS_SCALED_DOWN=true

# ──────────────── Helper: ensure standalone PVC exists ────────────────
# For PVCs using existingClaim (e.g. grafana-data) that must pre-exist
# before the workload starts. Creates the PVC if it is missing.
# Args: ns pvc_name storage_class size
ensure_standalone_pvc() {
  local ns="$1" pvc_name="$2" storage_class="$3" size="$4"
  if kubectl get pvc "${pvc_name}" -n "${ns}" >/dev/null 2>&1; then
    echo "   ✅ PVC ${pvc_name} already exists"
    return 0
  fi
  echo "   ⏳ Creating PVC ${pvc_name} (${size}, storageClass: ${storage_class})..."
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: restore-script
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: ${size}
EOF
  local retries=0
  until kubectl get pvc "${pvc_name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null \
    | grep -q "Bound"; do
    sleep 3
    retries=$((retries + 1))
    if [ "${retries}" -ge 20 ]; then
      echo "   ❌ Timeout waiting for PVC ${pvc_name} to bind"
      return 1
    fi
  done
  echo "   ✅ PVC ${pvc_name} bound"
}

# ──────────────── Helper: ensure StatefulSet PVC exists ────────────────
# Patches the Operator CR to start the pod briefly (creates PVC), then stops it.
# Args: cr_kind cr_name ns pvc_name pod_name
ensure_statefulset_pvc() {
  local cr_kind="$1" cr_name="$2" ns="$3" pvc_name="$4" pod_name="$5"
  if kubectl get pvc "${pvc_name}" -n "${ns}" >/dev/null 2>&1; then
    echo "   ✅ PVC ${pvc_name} already exists"
    return 0
  fi
  echo "   ⏳ Starting ${cr_name} briefly to create PVC ${pvc_name}..."
  kubectl patch "${cr_kind}" "${cr_name}" -n "${ns}" -p '{"spec":{"replicas":1}}' --type=merge 2>/dev/null || true
  local retries=0
  until kubectl get pvc "${pvc_name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null \
    | grep -q "Bound"; do
    sleep 5
    retries=$((retries + 1))
    if [ "${retries}" -ge 36 ]; then
      echo "   ❌ Timeout waiting for PVC ${pvc_name}"
      kubectl patch "${cr_kind}" "${cr_name}" -n "${ns}" -p '{"spec":{"replicas":0}}' --type=merge >/dev/null 2>&1 || true
      return 1
    fi
  done
  echo "   ✅ PVC ${pvc_name} bound"
  kubectl patch "${cr_kind}" "${cr_name}" -n "${ns}" -p '{"spec":{"replicas":0}}' --type=merge 2>/dev/null || true
  kubectl wait --for=delete "pod/${pod_name}" -n "${ns}" --timeout=660s 2>/dev/null || {
    kubectl delete pod "${pod_name}" -n "${ns}" --grace-period=0 --force 2>/dev/null || true
    kubectl wait --for=delete "pod/${pod_name}" -n "${ns}" --timeout=60s 2>/dev/null || true
  }
  # Give the NFS server a moment to flush before next mount
  sleep 5
}

# ──────────────── Helper: restore archive into a PVC via temp sleeping pod ────────────────
restore_pvc() {
  local ns="$1" pvc_name="$2" mount_path="$3" archive="$4"
  local pod_name
  pod_name="nfs-rst-$(echo "${pvc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-36)"

  if [ ! -f "${archive}" ]; then
    echo "   ⚠️  Archive not found: ${archive}, skipping ${pvc_name}"
    return 0
  fi
  if ! kubectl get pvc "${pvc_name}" -n "${ns}" >/dev/null 2>&1; then
    echo "   ❌ PVC ${ns}/${pvc_name} not found — skipping (run 'terraform apply' first)"
    return 1
  fi

  # Clean up any leftover pod from a previous failed run
  if kubectl get pod "${pod_name}" -n "${ns}" >/dev/null 2>&1; then
    echo "   🗑️  Removing leftover pod ${pod_name}..."
    kubectl delete pod "${pod_name}" -n "${ns}" --grace-period=0 --force 2>/dev/null || true
    kubectl wait --for=delete "pod/${pod_name}" -n "${ns}" --timeout=60s 2>/dev/null || true
  fi

  echo "   ♻️  ${archive##*/} → ${ns}/${pvc_name}"

  kubectl run "${pod_name}" -n "${ns}" --restart=Never --rm=false \
    --image="${IMAGE}" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"restore\",
          \"image\": \"${IMAGE}\",
          \"command\": [\"sh\", \"-c\", \"sleep 3600\"],
          \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"${mount_path}\"}]
        }],
        \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"${pvc_name}\"}}],
        \"restartPolicy\": \"Never\"
      }
    }" >/dev/null 2>&1

  if ! kubectl wait pod "${pod_name}" -n "${ns}" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
    echo "   ❌ Temp pod ${pod_name} failed to become Ready"
    kubectl delete pod "${pod_name}" -n "${ns}" --ignore-not-found=true --grace-period=0 --force >/dev/null 2>&1 || true
    return 1
  fi

  if ! kubectl exec -i -n "${ns}" "${pod_name}" -- \
      tar xzf - --directory="${mount_path}" < "${archive}"; then
    echo "      ❌ tar failed for ${pvc_name}"
    kubectl delete pod "${pod_name}" -n "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true
    return 1
  fi

  echo "      ✅ Done"
  kubectl delete pod "${pod_name}" -n "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true
}

# ──────────────── Ensure StatefulSet PVCs exist ────────────────
echo ""
echo "🔧 Ensuring PVCs exist..."
ensure_standalone_pvc  "monitoring" "grafana-data"                                      "nfs" "5Gi"            || ERRORS=$((ERRORS+1))
ensure_statefulset_pvc "prometheus"   "obs-prometheus"   "monitoring" "prometheus-data-prometheus-obs-prometheus-0"       "prometheus-obs-prometheus-0"   || ERRORS=$((ERRORS+1))
ensure_statefulset_pvc "alertmanager" "obs-alertmanager" "monitoring" "alertmanager-data-alertmanager-obs-alertmanager-0" "alertmanager-obs-alertmanager-0" || ERRORS=$((ERRORS+1))

# ──────────────── Restore ────────────────
echo ""
echo "♻️  Restoring data..."
restore_pvc "n8n"        "n8n-data"                                          "/home/node/.n8n"  "${BACKUP_DIR}/n8n.tar.gz"          || ERRORS=$((ERRORS+1))
restore_pvc "monitoring" "grafana-data"                                      "/var/lib/grafana" "${BACKUP_DIR}/grafana.tar.gz"       || ERRORS=$((ERRORS+1))
restore_pvc "monitoring" "prometheus-data-prometheus-obs-prometheus-0"       "/prometheus"      "${BACKUP_DIR}/prometheus.tar.gz"   || ERRORS=$((ERRORS+1))
restore_pvc "monitoring" "alertmanager-data-alertmanager-obs-alertmanager-0" "/alertmanager"    "${BACKUP_DIR}/alertmanager.tar.gz" || ERRORS=$((ERRORS+1))

# ──────────────── Summary ────────────────
# (scale_up always runs via the EXIT trap above)

echo ""
if [ "${ERRORS}" -gt 0 ]; then
  echo "⚠️  Restore completed with ${ERRORS} error(s). Check output above."
  exit 1
else
  echo "✅ Restore complete."
fi
echo ""
echo "📋 Verify XFS quotas:"
echo "   NFS_POD=\$(kubectl get pod -n nfs-storage -l app=nfs-server-provisioner -o jsonpath='{.items[0].metadata.name}')"
echo "   kubectl exec -n nfs-storage \"\${NFS_POD}\" -- xfs_quota -x -c 'report -h' /export"
