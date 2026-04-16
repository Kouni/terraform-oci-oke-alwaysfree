#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# NFS PVC Backup Script
#
# Back up all NFS-backed PVC data to local backups/ directory.
# Scales down related workloads before backup to ensure data consistency, then scales back up after completion.
#
# Usage: ./scripts/backup-nfs-data.sh [--skip-scaledown]
#   --skip-scaledown  Skip scale down (not recommended, but use when services cannot be stopped)
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
command -v kubectl >/dev/null 2>&1 || { echo "[ERROR] kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[ERROR] Cannot reach cluster"; exit 1; }

echo "[*]  NFS PVC Backup"
echo "   Target: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"

# ──────────────── Helper: exec tar from a running pod (binary-safe) ────────────────
backup_from_running_pod() {
  local ns="$1" pod="$2" container_path="$3" outfile="$4"
  echo "   [*] ${ns}/${pod}:${container_path} → ${outfile}"
  kubectl exec -n "${ns}" "${pod}" -- \
    tar czf - --directory="${container_path}" . \
    > "${BACKUP_SUBDIR}/${outfile}"
  local size
  size=$(du -sh "${BACKUP_SUBDIR}/${outfile}" | cut -f1)
  echo "      [OK] ${size}"
}

# ──────────────── Helper: backup a PVC via a temp sleeping pod (binary-safe) ────────────────
# The pod sleeps; we exec tar and pipe its stdout to a local file.
# kubectl logs is NOT used — it corrupts binary (gzip) data.
backup_pvc() {
  local ns="$1" pvc_name="$2" mount_path="$3" outfile="$4"
  local pod_name
  pod_name="nfs-bkp-$(echo "${pvc_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-36)"

  echo "   [*] ${ns}/${pvc_name} → ${outfile}"

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
  echo "      [OK] ${size}"

  kubectl delete pod "${pod_name}" -n "${ns}" --ignore-not-found=true >/dev/null 2>&1 || true
}

# ──────────────── Scale down ────────────────
if [ "${SKIP_SCALEDOWN}" = "false" ]; then
  echo ""
  echo "[*]  Scaling down workloads..."
  kubectl scale deployment n8n-main -n n8n --replicas=0 2>/dev/null && echo "   [OK] n8n-main" || echo "   [!]  n8n-main not found"
  echo "   [*] Waiting for pods to terminate..."
  kubectl wait --for=delete pod -n n8n -l app.kubernetes.io/name=n8n --timeout=120s 2>/dev/null || true
  echo "   [OK] All targeted pods terminated"
fi

# ──────────────── Backup ────────────────
echo ""
echo "[*] Backing up PVC data..."

if [ "${SKIP_SCALEDOWN}" = "true" ]; then
  N8N_POD=$(kubectl get pod -n n8n -l app.kubernetes.io/name=n8n \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  [ -n "${N8N_POD}" ] && backup_from_running_pod n8n "${N8N_POD}" /home/node/.n8n n8n.tar.gz
else
  backup_pvc n8n "n8n-data" "/home/node/.n8n" "n8n.tar.gz"
fi

# ──────────────── Scale back up ────────────────
if [ "${SKIP_SCALEDOWN}" = "false" ]; then
  echo ""
  echo "[*]  Scaling workloads back up..."
  kubectl scale deployment n8n-main -n n8n --replicas=1 2>/dev/null && echo "   [OK] n8n-main" || true
fi

# ──────────────── Summary ────────────────
echo ""
echo "[OK] Backup complete: ${BACKUP_SUBDIR}"
echo ""
ls -lh "${BACKUP_SUBDIR}"
echo ""
echo "[*] To restore after NFS migration, run:"
echo "   ./scripts/restore-nfs-data.sh ${BACKUP_SUBDIR}"
