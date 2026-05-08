# Scripts

Operational scripts for backup, restore, and infrastructure lifecycle. All scripts that interact with Kubernetes require `kubectl` with a valid kubeconfig pointing to the target OKE cluster.

## destroy.sh

Safely tears down the infrastructure by removing in-cluster Kubernetes and Helm resources from Terraform state before running `terraform destroy`. This prevents a known failure mode:

- Helm/Kubernetes provider **context deadline exceeded** when the OKE API server becomes unreachable after nodes are terminated.

OCI deletes all in-cluster resources (namespaces, PVCs, Deployments, Helm releases) automatically when the OKE cluster is destroyed — Terraform does not need to manage their individual deletion.

**Requires**: `terraform`

```bash
bash scripts/destroy.sh               # interactive confirmation
bash scripts/destroy.sh -auto-approve # non-interactive
```

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
