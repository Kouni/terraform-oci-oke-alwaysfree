# HedgeDoc Deployment Guide

> [!] **This guide is a manual deployment reference and is not managed by Terraform.**
> HedgeDoc is not integrated into this project's Terraform configuration (no corresponding resources in `main.tf`).
> This document describes how to **manually** deploy HedgeDoc on an existing OKE cluster,
> using `k8s/hedgedoc-namespace.yaml` and `k8s/hedgedoc-secrets.yaml` as a starting point.

> **Goal:** Manually deploy HedgeDoc (a collaborative Markdown editor) on the existing OKE Always Free cluster
> using Helm commands, with a PostgreSQL database, served externally via the existing Cloudflare Tunnel.

---

## Architecture Overview

```mermaid
graph TB
    Browser["Browser"]
    CF["Cloudflare Edge<br/>(Zero Trust + Access)"]

    subgraph OKE["OKE Cluster — VM.Standard.A1.Flex (4 OCPU / 24 GB / ARM64)"]

        subgraph NS_TUNNEL["namespace: tunnel (existing)"]
            CFD["cloudflared<br/>(outbound connector)"]
        end

        subgraph NS_HEDGEDOC["namespace: hedgedoc (new)"]
            HD["HedgeDoc<br/>Deployment / Port 3000<br/>NFS PVC (uploads)"]
            PG["PostgreSQL (Bitnami Helm)<br/>Port 5432<br/>NFS PVC (data)"]
        end

    end

    Browser -->|"HTTPS"| CF
    CF -->|"hedgedoc.your-domain.com"| CFD
    CFD -->|"http :3000"| HD
    HD -->|"CMD_DB_URL"| PG

    classDef external fill:#e65100,color:#fff,stroke:#ff6d00,stroke-width:2px
    classDef new_ns fill:#1a237e,color:#fff,stroke:#5c6bc0,stroke-width:1px
    classDef existing fill:#2e7d32,color:#fff,stroke:#66bb6a,stroke-width:1px

    class Browser,CF external
    class HD,PG new_ns
    class CFD existing

    style NS_TUNNEL fill:#1b3a1b,color:#fff,stroke:#66bb6a,stroke-width:1px,stroke-dasharray:4 4
    style NS_HEDGEDOC fill:#0d1b4a,color:#fff,stroke:#5c6bc0,stroke-width:2px
    style OKE fill:#1c2833,color:#fff,stroke:#546e7a,stroke-width:2px,stroke-dasharray:6 4
```

**Design Decisions:**
- HedgeDoc 1.x (stable release); not using 2.x which is still in development
- PostgreSQL managed by Bitnami Helm chart, data stored on NFS StorageClass
- ClusterIP Service; no LoadBalancer (Always Free has no spare LB quota)
- Traffic routed via existing shared Cloudflare Tunnel; only requires adding a new Public Hostname in the Dashboard

---

## Prerequisites

- [ ] `kubectl` is configured and can connect to the cluster (`kubectl get nodes` works)
- [ ] Terraform is initialized (`terraform init` has been run)
- [ ] Existing Terraform has enabled: `enable_nfs_storage = true`, `enable_cloudflare_tunnel = true`
- [ ] Cloudflare Zero Trust account with an existing running Tunnel
- [ ] An available subdomain, e.g. `hedgedoc.your-domain.com`

---

## Step 1: Generate Secrets

```bash
# PostgreSQL password
PG_PASSWORD=$(openssl rand -base64 24)
echo "PostgreSQL password: $PG_PASSWORD"

# HedgeDoc session secret
SESSION_SECRET=$(openssl rand -hex 32)
echo "Session secret: $SESSION_SECRET"
```

> Save these two values securely; they will be needed in subsequent steps.

---

## Step 2: Edit and Apply K8s Secrets

### 2.1 Edit the Secret Template

Edit `k8s/hedgedoc-secrets.yaml` and replace the following fields:

| Field | Replace With |
|-------|-------------|
| `<REPLACE: hedgedoc_pg_password>` in `CMD_DB_URL` | PG_PASSWORD from Step 1 |
| `CMD_SESSION_SECRET` | SESSION_SECRET from Step 1 |
| `CMD_DOMAIN` | Your actual domain (e.g. `hedgedoc.example.com`) |

The completed `CMD_DB_URL` format:
```
postgres://hedgedoc:YOUR_PG_PASSWORD@hedgedoc-postgresql.hedgedoc.svc.cluster.local:5432/hedgedoc
```

### 2.2 Apply to the Cluster

```bash
kubectl apply -f k8s/hedgedoc-namespace.yaml
kubectl apply -f k8s/hedgedoc-secrets.yaml
```

### 2.3 Verify

```bash
kubectl get namespace hedgedoc
kubectl get secret hedgedoc-secrets -n hedgedoc
```

---

## Step 3: Configure Terraform Variables

Add the following to `terraform.tfvars`:

```hcl
enable_hedgedoc      = true
hedgedoc_pg_password = "PG_PASSWORD from Step 1"
```

> **Important:** `hedgedoc_pg_password` must **exactly match** the password in `CMD_DB_URL` in `k8s/hedgedoc-secrets.yaml`.
> Terraform uses this password to create PostgreSQL, and HedgeDoc uses `CMD_DB_URL` from the Secret to connect. A mismatch will cause connection failure.

Other variables can be adjusted as needed (all have default values):

| Variable | Default | Description |
|----------|---------|-------------|
| `hedgedoc_namespace` | `hedgedoc` | K8s namespace |
| `hedgedoc_image_tag` | `1.10.2` | HedgeDoc image version |
| `hedgedoc_pvc_size` | `2Gi` | Upload files PVC size |
| `hedgedoc_secret_name` | `hedgedoc-secrets` | K8s Secret name |
| `hedgedoc_pg_pvc_size` | `5Gi` | PostgreSQL PVC size |

---

## Step 4: Terraform Apply

```bash
terraform plan
terraform apply
```

Expected new resources:
- `terraform_data.hedgedoc_validation[0]`
- `helm_release.hedgedoc_postgresql[0]`
- `kubernetes_persistent_volume_claim_v1.hedgedoc[0]`
- `kubernetes_deployment_v1.hedgedoc[0]`
- `kubernetes_service_v1.hedgedoc[0]`

---

## Step 5: Cloudflare Tunnel -- Add Public Hostname

1. Open [Cloudflare Zero Trust](https://one.dash.cloudflare.com)
2. Left menu -> **Networks** -> **Tunnels**
3. Find the existing Tunnel -> click **Configure** -> **Public Hostname** tab
4. Click **Add a public hostname** and fill in:

| Field | Value |
|-------|-------|
| Subdomain | `hedgedoc` |
| Domain | `your-domain.com` |
| Type | `HTTP` |
| URL | `hedgedoc.hedgedoc.svc.cluster.local:3000` |

> Cloudflare will automatically create the DNS record. The configuration takes effect approximately 30 seconds after saving.

---

## Step 6: Cloudflare Access -- Configure Access Control (Recommended)

Without Access configured, anyone who knows the domain can access HedgeDoc.

1. Zero Trust -> **Access** -> **Applications** -> **Add an application**
2. Select **Self-hosted**
3. Fill in:

   | Field | Value |
   |-------|-------|
   | Application name | `HedgeDoc` |
   | Session Duration | `24 hours` |
   | Application domain | `hedgedoc.your-domain.com` |

4. Create a Policy:

   | Field | Value |
   |-------|-------|
   | Policy name | `Allow Me` |
   | Action | `Allow` |
   | Include | `Emails` -> enter your email |

5. Click **Save**

---

## Step 7: Verification Checklist

```bash
# Confirm all Pods are running
kubectl get pods -n hedgedoc

# Confirm all PVCs are Bound
kubectl get pvc -n hedgedoc

# Check PostgreSQL logs
kubectl logs -n hedgedoc -l app.kubernetes.io/name=postgresql --tail=20

# Check HedgeDoc logs
kubectl logs -n hedgedoc deploy/hedgedoc --tail=20

# Test HTTPS connectivity
curl -I https://hedgedoc.your-domain.com
```

**Expected results:**
- PostgreSQL Pod: 1/1 Running
- HedgeDoc Pod: 1/1 Running
- Two PVCs: Bound
- `curl` returns HTTP 200 or 302 (Cloudflare Access redirect)

---

## Resource Usage Estimate

| Workload | CPU request | Memory request |
|----------|-------------|----------------|
| hedgedoc-postgresql | 50m | 128 Mi |
| hedgedoc | 100m | 256 Mi |
| **HedgeDoc Total** | **150m** | **384 Mi** |

**Storage (NFS):**
- PostgreSQL PVC: 5 Gi (default)
- HedgeDoc uploads PVC: 2 Gi (default)
- Total added: 7 Gi

---

## Upgrades

### Upgrade HedgeDoc Version

Edit `terraform.tfvars`:

```hcl
hedgedoc_image_tag = "1.10.3"  # New version
```

```bash
terraform apply
```

### Upgrade PostgreSQL

PostgreSQL is managed by the Bitnami Helm chart; Terraform handles the Helm release upgrade.
Before upgrading, review the [Bitnami PostgreSQL chart changelog](https://github.com/bitnami/charts/tree/main/bitnami/postgresql).

> **Note:** PostgreSQL major version upgrades (e.g. 15 -> 16) require data migration and cannot be done by simply updating the chart.

---

## Backup

### Database Backup

```bash
# Run pg_dump inside the Pod
kubectl exec -n hedgedoc hedgedoc-postgresql-0 -- \
  pg_dump -U hedgedoc hedgedoc > hedgedoc-backup-$(date +%Y%m%d).sql
```

### Restore

```bash
kubectl exec -i -n hedgedoc hedgedoc-postgresql-0 -- \
  psql -U hedgedoc hedgedoc < hedgedoc-backup-YYYYMMDD.sql
```

---

## Important Notes

- Losing `CMD_SESSION_SECRET` will invalidate all existing user sessions; be sure to back it up
- `hedgedoc_pg_password` in `terraform.tfvars` and `CMD_DB_URL` in `k8s/hedgedoc-secrets.yaml` **must be identical**
- HedgeDoc uses the stable 1.x release; 2.x is still in development and not recommended for production
- Uploaded files are stored at `/hedgedoc/public/uploads` in the NFS PVC, sized by `hedgedoc_pvc_size`

---

## Cleanup (Remove HedgeDoc)

### 1. Terraform

Edit `terraform.tfvars`:

```hcl
enable_hedgedoc = false
```

```bash
terraform apply
```

### 2. Remove K8s Resources

```bash
# Remove residual PVCs (Helm-created PVCs may remain after Terraform removal)
kubectl delete pvc -n hedgedoc --all

# Remove Secrets and Namespace
kubectl delete -f k8s/hedgedoc-secrets.yaml
kubectl delete -f k8s/hedgedoc-namespace.yaml
```

### 3. Cloudflare Cleanup

Manually remove the following from the Cloudflare Zero Trust dashboard:
- **Public Hostname**: `hedgedoc.your-domain.com`
- **Access Application**: `HedgeDoc` (if created)
