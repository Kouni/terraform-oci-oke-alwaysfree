#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# n8n Backup Script
#
# Back up n8n K8s Secrets, SQLite database, and Helm values to local backups/ directory.
# Backup files contain real sensitive data. Store them securely.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077

NAMESPACE="${1:-n8n}"
TUNNEL_NS="${2:-tunnel}"
MAX_BACKUPS=7
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d%H%M)"
BACKUP_SUBDIR="${BACKUP_DIR}/${TIMESTAMP}"

# ──────────────── Preflight checks ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "[ERROR] kubectl not found"; exit 1; }
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || { echo "[ERROR] Namespace '${NAMESPACE}' not found"; exit 1; }

echo "[*] Backing up n8n secrets from namespace '${NAMESPACE}'..."
echo "   Target: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"

# ──────────────── Backup Secrets (YAML) ────────────────
echo "[*] Exporting Kubernetes Secrets..."
for secret in n8n-secrets; do
  if kubectl get secret "${secret}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl get secret "${secret}" -n "${NAMESPACE}" -o yaml > "${BACKUP_SUBDIR}/${secret}.yaml"
    echo "   [OK] ${secret} (ns: ${NAMESPACE})"
  else
    echo "   [!]  ${secret} not found in ${NAMESPACE}, skipping"
  fi
done
if kubectl get secret cloudflare-tunnel -n "${TUNNEL_NS}" >/dev/null 2>&1; then
  kubectl get secret cloudflare-tunnel -n "${TUNNEL_NS}" -o yaml > "${BACKUP_SUBDIR}/cloudflare-tunnel.yaml"
  echo "   [OK] cloudflare-tunnel (ns: ${TUNNEL_NS})"
else
  echo "   [!]  cloudflare-tunnel not found in ${TUNNEL_NS}, skipping"
fi

# ──────────────── Extract plaintext keys (for password manager) ────────────────
echo "[*] Extracting plaintext keys..."
KEYS_FILE="${BACKUP_SUBDIR}/plaintext-keys.txt"
cat > "${KEYS_FILE}" <<EOF
# n8n Secrets Backup — ${TIMESTAMP}
# [!]  This file contains sensitive data. Store in a password manager and then delete.

EOF

if kubectl get secret n8n-secrets -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "## n8n-secrets" >> "${KEYS_FILE}"
  for key in N8N_ENCRYPTION_KEY N8N_HOST N8N_PORT N8N_PROTOCOL; do
    val=$(kubectl get secret n8n-secrets -n "${NAMESPACE}" -o jsonpath="{.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || echo "<not found>")
    echo "${key}=${val}" >> "${KEYS_FILE}"
  done
  echo "" >> "${KEYS_FILE}"
fi

if kubectl get secret cloudflare-tunnel -n "${TUNNEL_NS}" >/dev/null 2>&1; then
  echo "## cloudflare-tunnel (namespace: ${TUNNEL_NS})" >> "${KEYS_FILE}"
  val=$(kubectl get secret cloudflare-tunnel -n "${TUNNEL_NS}" -o jsonpath='{.data.TUNNEL_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || echo "<not found>")
  echo "TUNNEL_TOKEN=${val}" >> "${KEYS_FILE}"
  echo "" >> "${KEYS_FILE}"
fi

# ──────────────── Backup n8n SQLite database ────────────────
echo "[*] Backing up n8n SQLite database..."
N8N_POD=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${N8N_POD}" ]; then
  # Trigger SQLite checkpoint to flush WAL to main database
  kubectl exec -n "${NAMESPACE}" "${N8N_POD}" -- \
    sqlite3 /home/node/.n8n/database.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  kubectl cp "${NAMESPACE}/${N8N_POD}:/home/node/.n8n/database.sqlite" \
    "${BACKUP_SUBDIR}/database.sqlite" 2>/dev/null && \
    echo "   [OK] database.sqlite ($(du -h "${BACKUP_SUBDIR}/database.sqlite" | cut -f1))" || \
    echo "   [!]  Failed to copy database.sqlite"
else
  echo "   [!]  n8n pod not found, skipping database backup"
fi

# ──────────────── Backup Helm release info ────────────────
echo "[*] Exporting Helm release info..."
if command -v helm >/dev/null 2>&1; then
  helm get values n8n -n "${NAMESPACE}" -o yaml > "${BACKUP_SUBDIR}/helm-values.yaml" 2>/dev/null && \
    echo "   [OK] helm-values.yaml" || echo "   [!]  n8n helm release not found"
else
  echo "   [!]  helm not found, skipping"
fi

# ──────────────── Rotation (keep latest MAX_BACKUPS) ────────────────
BACKUP_COUNT=$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | wc -l | tr -d ' ')
if [ "${BACKUP_COUNT}" -gt "${MAX_BACKUPS}" ]; then
  REMOVE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
  echo "[*]  Rotating old backups (keeping latest ${MAX_BACKUPS})..."
  find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | head -n "${REMOVE_COUNT}" | while read -r old_dir; do
    echo "   [*]  Removing ${old_dir}"
    rm -rf "${old_dir}"
  done
fi

# ──────────────── Summary ────────────────
echo ""
echo "[OK] Backup complete: ${BACKUP_SUBDIR}"
echo ""
ls -lh "${BACKUP_SUBDIR}"
echo ""
echo "[!]  Important reminders:"
echo "   1. plaintext-keys.txt contains plaintext keys. Store in a password manager and consider deleting it."
echo "   2. The backups/ directory is excluded by .gitignore and will not be committed to version control."
echo "   3. N8N_ENCRYPTION_KEY is the most critical backup item. Losing it makes n8n credentials unrecoverable."
