# Scripts

Operational scripts for backup and restore. All scripts require `kubectl` with a valid kubeconfig pointing to the target OKE cluster.

## backup-n8n.sh

Backs up n8n Kubernetes Secrets, SQLite database, and Helm values to `backups/`.

```bash
./scripts/backup-n8n.sh [namespace] [tunnel-namespace]
# Defaults: namespace=n8n, tunnel-namespace=tunnel
```

## backup-nfs-data.sh

Backs up the n8n NFS-backed PVC data to `backups/`. Automatically scales down n8n before backup and scales back up after.

```bash
./scripts/backup-nfs-data.sh [--skip-scaledown]
```

## restore-nfs-data.sh

Restores n8n PVC data from a backup created by `backup-nfs-data.sh`. Used after NFS backing volume migration (e.g., ext4 → XFS).

```bash
./scripts/restore-nfs-data.sh <backup-directory>
```

> **Security**: Backup files contain sensitive data (encryption keys, credentials). The scripts set `umask 077` so only the owner can read backup files.
