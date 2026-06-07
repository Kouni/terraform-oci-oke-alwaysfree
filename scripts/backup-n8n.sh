#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Complete Backup Script
#
# Backs up all K8s Secrets, n8n SQLite database, all Helm release values, and
# Terraform config to backups/<TIMESTAMP>/. Run backup-nfs-data.sh separately
# for NFS PVC data (requires n8n scale-down).
#
# Backup files contain sensitive data. Store them securely.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail
umask 077

MAX_BACKUPS=7
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKUP_DIR="${REPO_DIR}/backups"
TIMESTAMP="$(date +%Y%m%d%H%M)"
BACKUP_SUBDIR="${BACKUP_DIR}/${TIMESTAMP}"

# ──────────────── Preflight checks ────────────────
command -v kubectl >/dev/null 2>&1 || { echo "[ERROR] kubectl not found"; exit 1; }
kubectl cluster-info >/dev/null 2>&1 || { echo "[ERROR] Cannot reach cluster"; exit 1; }

echo "[*] Complete backup — ${TIMESTAMP}"
echo "   Target: ${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}"
mkdir -p "${BACKUP_SUBDIR}/terraform"

# ──────────────── Helper: backup a single K8s secret ────────────────
backup_secret() {
  local ns="$1"
  local name="$2"
  local outfile="${BACKUP_SUBDIR}/${3:-${name}.yaml}"
  if kubectl get secret "${name}" -n "${ns}" >/dev/null 2>&1; then
    # Strip server-managed fields so the exported YAML can be cleanly re-applied
    # to a fresh cluster without resourceVersion/uid conflicts.
    kubectl get secret "${name}" -n "${ns}" -o yaml \
      | yq 'del(
          .metadata.resourceVersion,
          .metadata.uid,
          .metadata.creationTimestamp,
          .metadata.managedFields,
          .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
          .status
        )' > "${outfile}"
    echo "   [OK] ${ns}/${name}"
  else
    echo "   [!]  ${ns}/${name} not found, skipping"
  fi
}

# ──────────────── Helper: decode a secret field to plaintext ────────────────
decode_secret_field() {
  local ns="$1" name="$2" key="$3"
  kubectl get secret "${name}" -n "${ns}" -o "jsonpath={.data.${key}}" 2>/dev/null \
    | base64 -d 2>/dev/null || echo "<not found>"
}

# ──────────────── Backup Secrets (all namespaces) ────────────────
echo ""
echo "[*] Exporting Kubernetes Secrets..."
backup_secret n8n           n8n-secrets
backup_secret n8n           n8n-registry-creds
backup_secret n8n           n8n-task-runners
backup_secret tunnel        cloudflare-tunnel
backup_secret monitoring    grafana-google-oauth
backup_secret tailscale     operator              tailscale-operator.yaml
backup_secret tailscale     operator-oauth        tailscale-operator-oauth.yaml

# ──────────────── Extract plaintext keys (for password manager) ────────────────
echo ""
echo "[*] Extracting plaintext keys..."
KEYS_FILE="${BACKUP_SUBDIR}/plaintext-keys.txt"
cat > "${KEYS_FILE}" <<EOF
# Complete Secrets Backup — ${TIMESTAMP}
# ⚠️  This file contains sensitive data. Store in a password manager and then delete.

EOF

{
  echo "## n8n/n8n-secrets"
  for key in N8N_ENCRYPTION_KEY N8N_HOST N8N_PORT N8N_PROTOCOL; do
    echo "${key}=$(decode_secret_field n8n n8n-secrets "${key}")"
  done
  echo ""
  echo "## tunnel/cloudflare-tunnel"
  echo "TUNNEL_TOKEN=$(decode_secret_field tunnel cloudflare-tunnel TUNNEL_TOKEN)"
  echo ""
  echo "## monitoring/grafana-google-oauth"
  echo "GF_AUTH_GOOGLE_CLIENT_ID=$(decode_secret_field monitoring grafana-google-oauth GF_AUTH_GOOGLE_CLIENT_ID)"
  echo "GF_AUTH_GOOGLE_CLIENT_SECRET=$(decode_secret_field monitoring grafana-google-oauth GF_AUTH_GOOGLE_CLIENT_SECRET)"
  echo ""
  echo "## tailscale/operator-oauth"
  echo "client_id=$(decode_secret_field tailscale operator-oauth client_id)"
  echo "client_secret=$(decode_secret_field tailscale operator-oauth client_secret)"
  echo ""
} >> "${KEYS_FILE}"
echo "   [OK] plaintext-keys.txt"

# ──────────────── Backup Terraform config ────────────────
echo ""
echo "[*] Backing up Terraform config..."
if [ -f "${REPO_DIR}/terraform.tfvars" ]; then
  cp "${REPO_DIR}/terraform.tfvars" "${BACKUP_SUBDIR}/terraform/terraform.tfvars"
  echo "   [OK] terraform.tfvars"
else
  echo "   [!]  terraform.tfvars not found, skipping"
fi
if [ -f "${REPO_DIR}/terraform.tfstate" ]; then
  cp "${REPO_DIR}/terraform.tfstate" "${BACKUP_SUBDIR}/terraform/terraform.tfstate"
  echo "   [OK] terraform.tfstate"
else
  echo "   [!]  terraform.tfstate not found, skipping"
fi

# ──────────────── Backup n8n SQLite database ────────────────
echo ""
echo "[*] Backing up n8n SQLite database..."
N8N_POD=$(kubectl get pod -n n8n -l app.kubernetes.io/name=n8n \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "${N8N_POD}" ]; then
  # Flush WAL to main database before copy
  kubectl exec -n n8n "${N8N_POD}" -- \
    sqlite3 /home/node/.n8n/database.sqlite "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
  kubectl cp "n8n/${N8N_POD}:/home/node/.n8n/database.sqlite" \
    "${BACKUP_SUBDIR}/database.sqlite" 2>/dev/null && \
    echo "   [OK] database.sqlite ($(du -h "${BACKUP_SUBDIR}/database.sqlite" | cut -f1))" || \
    echo "   [!]  Failed to copy database.sqlite"
else
  echo "   [!]  n8n pod not found, skipping database backup"
fi

# ──────────────── Backup all Helm release values ────────────────
echo ""
echo "[*] Exporting Helm release values..."
if command -v helm >/dev/null 2>&1; then
  while IFS=$'\t' read -r release ns; do
    [ -z "${release}" ] && continue
    outfile="${BACKUP_SUBDIR}/helm-${ns}-${release}.yaml"
    helm get values "${release}" -n "${ns}" -o yaml > "${outfile}" 2>/dev/null && \
      echo "   [OK] ${ns}/${release}" || echo "   [!]  ${ns}/${release} values not found"
  done < <(helm list --all-namespaces -o json 2>/dev/null \
    | python3 -c "import sys,json; [print(r['name']+'\t'+r['namespace']) for r in json.load(sys.stdin)]" \
    2>/dev/null || true)
else
  echo "   [!]  helm not found, skipping"
fi

# ──────────────── Rotation (keep latest MAX_BACKUPS) ────────────────
BACKUP_COUNT=$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | wc -l | tr -d ' ')
if [ "${BACKUP_COUNT}" -gt "${MAX_BACKUPS}" ]; then
  REMOVE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
  echo ""
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
ls -lhR "${BACKUP_SUBDIR}"
echo ""
echo "[!]  Important reminders:"
echo "   1. plaintext-keys.txt and terraform/terraform.tfvars contain sensitive data."
echo "      The backups/ directory is excluded by .gitignore and will not be committed."
echo "   2. N8N_ENCRYPTION_KEY is critical — losing it makes all n8n credentials unrecoverable."
echo "   3. Run ./scripts/backup-nfs-data.sh separately to back up NFS PVC data."
echo ""
echo "   Restore (same cluster):"
echo "      for f in \"${BACKUP_SUBDIR}\"/*.yaml; do kubectl apply -f \"\$f\"; done"
echo "      ./scripts/restore-nfs-data.sh <nfs-backup-dir>"
echo ""
echo "   Restore (new cluster):"
echo "      cp \"${BACKUP_SUBDIR}/terraform/terraform.tfvars\" ."
echo "      terraform apply"
echo "      for f in \"${BACKUP_SUBDIR}\"/*.yaml; do kubectl apply -f \"\$f\"; done"
echo "      ./scripts/restore-nfs-data.sh <nfs-backup-dir>"
