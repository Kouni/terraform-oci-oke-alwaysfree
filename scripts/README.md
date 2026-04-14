# Scripts

Operational scripts for backup and restore. All scripts require `kubectl` with a valid kubeconfig pointing to the target OKE cluster.

## backup-n8n.sh

Backs up n8n Kubernetes Secrets, SQLite database, and Helm values to `backups/`.

```bash
./scripts/backup-n8n.sh [namespace] [tunnel-namespace]
# Defaults: namespace=n8n, tunnel-namespace=tunnel
```

## backup-nfs-data.sh

Backs up all NFS-backed PVC data to `backups/`.

```bash
./scripts/backup-nfs-data.sh
```

## restore-nfs-data.sh

Restores PVC data from a backup created by `backup-nfs-data.sh`.

```bash
./scripts/restore-nfs-data.sh <backup-directory>
```

> **Security**: Backup files contain sensitive data (encryption keys, credentials). The scripts set `umask 077` so only the owner can read backup files.
