#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# n8n Backup Script
#
# 備份 n8n 的 K8s Secrets、SQLite 資料庫、Helm values 到本地 backups/ 目錄。
# 備份檔案包含真實機敏資料，請妥善保管。
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAMESPACE="${1:-n8n}"
TUNNEL_NS="${2:-tunnel}"
MAX_BACKUPS=7
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d%H%M)"
BACKUP_SUBDIR="${BACKUP_DIR}/${TIMESTAMP}"

# ──────────────── Preflight checks ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || { echo "❌ Namespace '${NAMESPACE}' not found"; exit 1; }

echo "🔐 Backing up n8n secrets from namespace '${NAMESPACE}'..."
echo "   Target: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"

# ──────────────── Backup Secrets (YAML) ────────────────
echo "📦 Exporting Kubernetes Secrets..."
for secret in n8n-secrets; do
  if kubectl get secret "${secret}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl get secret "${secret}" -n "${NAMESPACE}" -o yaml > "${BACKUP_SUBDIR}/${secret}.yaml"
    echo "   ✅ ${secret} (ns: ${NAMESPACE})"
  else
    echo "   ⚠️  ${secret} not found in ${NAMESPACE}, skipping"
  fi
done
if kubectl get secret cloudflare-tunnel -n "${TUNNEL_NS}" >/dev/null 2>&1; then
  kubectl get secret cloudflare-tunnel -n "${TUNNEL_NS}" -o yaml > "${BACKUP_SUBDIR}/cloudflare-tunnel.yaml"
  echo "   ✅ cloudflare-tunnel (ns: ${TUNNEL_NS})"
else
  echo "   ⚠️  cloudflare-tunnel not found in ${TUNNEL_NS}, skipping"
fi

# ──────────────── Extract plaintext keys (for password manager) ────────────────
echo "🔑 Extracting plaintext keys..."
KEYS_FILE="${BACKUP_SUBDIR}/plaintext-keys.txt"
cat > "${KEYS_FILE}" <<EOF
# n8n Secrets Backup — ${TIMESTAMP}
# ⚠️  此檔案包含機敏資料，請存入密碼管理器後刪除

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
echo "💾 Backing up n8n SQLite database..."
N8N_POD=$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=n8n -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${N8N_POD}" ]; then
  # Trigger SQLite checkpoint to flush WAL to main database
  kubectl exec -n "${NAMESPACE}" "${N8N_POD}" -- \
    sqlite3 /home/node/.n8n/database.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  kubectl cp "${NAMESPACE}/${N8N_POD}:/home/node/.n8n/database.sqlite" \
    "${BACKUP_SUBDIR}/database.sqlite" 2>/dev/null && \
    echo "   ✅ database.sqlite ($(du -h "${BACKUP_SUBDIR}/database.sqlite" | cut -f1))" || \
    echo "   ⚠️  Failed to copy database.sqlite"
else
  echo "   ⚠️  n8n pod not found, skipping database backup"
fi

# ──────────────── Backup Helm release info ────────────────
echo "📋 Exporting Helm release info..."
if command -v helm >/dev/null 2>&1; then
  helm get values n8n -n "${NAMESPACE}" -o yaml > "${BACKUP_SUBDIR}/helm-values.yaml" 2>/dev/null && \
    echo "   ✅ helm-values.yaml" || echo "   ⚠️  n8n helm release not found"
else
  echo "   ⚠️  helm not found, skipping"
fi

# ──────────────── Rotation (keep latest MAX_BACKUPS) ────────────────
BACKUP_COUNT=$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | wc -l | tr -d ' ')
if [ "${BACKUP_COUNT}" -gt "${MAX_BACKUPS}" ]; then
  REMOVE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
  echo "🗑️  Rotating old backups (keeping latest ${MAX_BACKUPS})..."
  find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | head -n "${REMOVE_COUNT}" | while read -r old_dir; do
    echo "   🗑️  Removing ${old_dir}"
    rm -rf "${old_dir}"
  done
fi

# ──────────────── Summary ────────────────
echo ""
echo "✅ Backup complete: ${BACKUP_SUBDIR}"
echo ""
ls -lh "${BACKUP_SUBDIR}"
echo ""
echo "⚠️  重要提醒："
echo "   1. plaintext-keys.txt 含有明文金鑰，請存入密碼管理器後考慮刪除"
echo "   2. backups/ 目錄已被 .gitignore 排除，不會進入版控"
echo "   3. N8N_ENCRYPTION_KEY 是最重要的備份項目，遺失將無法恢復 n8n 憑證"
