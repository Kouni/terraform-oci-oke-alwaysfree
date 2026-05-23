# OKE Always Free — Observability Stack

> **Scope:** Prometheus (metrics) + Grafana (dashboards) + AlertManager (notifications).
> Deployed manually via Helm. Not managed by Terraform.

## Architecture

```
Cloudflare Tunnel
grafana.kouni.io
       │
       ▼ HTTP / ClusterIP
┌──────────────┐
│   Grafana    │  Deployment × 1  │  NFS PVC 2Gi │
└──────┬───────┘
       │ PromQL
       ▼
┌──────────────┐     ┌──────────────┐
│  Prometheus  │────▶│ AlertManager │
│ NFS PVC 15Gi │     │ NFS PVC 1Gi  │
│ retention 30d│     │ retention 5d │
└──────▲───────┘     └──────────────┘
       │ scrape
┌──────┴───────────────────────────┐
│ Prometheus Operator              │
│ kube-state-metrics               │
│ node-exporter (DaemonSet × node) │
└──────────────────────────────────┘

All PVCs on in-cluster NFS StorageClass.
No Ingress / LoadBalancer — ClusterIP only.
```

## Storage Budget

| Component    | PVC Size | Policy                                                        |
|--------------|----------|---------------------------------------------------------------|
| Prometheus   | 5 Gi     | `retentionSize=4.5GB`, `retention=90d`, WAL compression on   |
| Grafana      | 2 Gi     | `helm.sh/resource-policy: keep` annotation                    |
| AlertManager | 1 Gi     | `retention=120h` (5 days)                                     |
| **Total**    | **8 Gi** | 6 % of 136 Gi NFS                                            |

Sizing basis: ~5050 active series (OCI infra only) × 30 s scrape interval ×
1.5 B/sample ≈ 253 B/s → **~2 GB at 90 days** (61 % headroom in 5 Gi PVC).

## Resource Budget

| Component          | CPU Req | Mem Req | CPU Limit | Mem Limit |
|--------------------|---------|---------|-----------|-----------|
| Prometheus         | 300m    | 512 Mi  | 1000m     | 1.5 Gi    |
| Grafana            | 100m    | 256 Mi  | 500m      | 768 Mi    |
| AlertManager       | 50m     | 128 Mi  | 200m      | 256 Mi    |
| kube-state-metrics | 50m     | 128 Mi  | 200m      | 256 Mi    |
| node-exporter      | 50m     | 64 Mi   | 200m      | 128 Mi    |
| Prometheus Operator| 100m    | 256 Mi  | 300m      | 512 Mi    |
| **Total Request**  | ~650m   | ~1.3 Gi |           |           |

A1.Flex available (after OS + system pods): ~3300m CPU, ~22 Gi RAM.

## Deployment

### Prerequisites

```bash
kubectl cluster-info                # cluster reachable
kubectl get sc nfs                  # NFS StorageClass must exist
helm version                        # Helm 3.x
```

### Step 1 — Namespace

```bash
kubectl apply -f k8s/monitoring/01_namespace.yaml
```

### Step 2 — Helm repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 3 — Install kube-prometheus-stack

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/values-kube-prometheus-stack.yaml \
  --wait --timeout 10m
```

### Step 4 — Verify pods and PVCs

```bash
kubectl -n monitoring get pods,pvc
```

All pods should reach `Running` / `Completed`. Three PVCs should be `Bound`:
- `prometheus-kube-prometheus-stack-prometheus-db-prometheus-...`
- `kube-prometheus-stack-grafana`
- `alertmanager-kube-prometheus-stack-alertmanager-db-alertmanager-...`

## External Access

### Cloudflare Tunnel (primary)

In the **Cloudflare Zero Trust Dashboard** → Networks → Tunnels → your tunnel → Edit → Public Hostnames, add:

| Field    | Value                                                     |
|----------|-----------------------------------------------------------|
| Hostname | `grafana.kouni.io`                                        |
| Service  | `http://kube-prometheus-stack-grafana.monitoring.svc:80`  |

Grafana is already configured with `root_url: https://grafana.kouni.io` and `cookie_secure: true`.

Verify: open `https://grafana.kouni.io` (default credentials: `admin` / `prom-operator`).

### Port-forward (local / fallback)

```bash
./scripts/port-forward-monitoring.sh
# Grafana:    http://localhost:3000
# Prometheus: http://localhost:9090
```

## Initial Setup

### Google OAuth (Single Sign-On)

Grafana is configured to use Google OAuth for authentication. The login form is disabled — all users sign in via Google.

#### Step 1 — Create Google OAuth Client

1. Go to [Google Cloud Console → APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials)
2. Click **Create Credentials → OAuth client ID**
3. Application type: **Web application**
4. Add **Authorized redirect URI**: `https://grafana.kouni.io/login/google`
5. Copy the generated **Client ID** and **Client Secret**

#### Step 2 — Create Kubernetes Secret

```bash
cp k8s/monitoring/secret-grafana-google-oauth.yaml.example \
   k8s/monitoring/secret-grafana-google-oauth.yaml

# Edit the file and fill in your Client ID and Secret:
#   GF_AUTH_GOOGLE_CLIENT_ID: "xxxx.apps.googleusercontent.com"
#   GF_AUTH_GOOGLE_CLIENT_SECRET: "xxxx"

kubectl apply -f k8s/monitoring/secret-grafana-google-oauth.yaml
```

> ⚠️ `secret-grafana-google-oauth.yaml` is in `.gitignore`. Only the `.example` file is committed.

#### Step 3 — Install / upgrade Helm chart

The `values-kube-prometheus-stack.yaml` already includes the OAuth config. A `helm upgrade` picks it up:

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/values-kube-prometheus-stack.yaml \
  --set grafana.adminPassword='<strong-password>' \
  --wait --timeout 10m
```

#### Access behaviour after setup

| Scenario | Behaviour |
|----------|-----------|
| Visit `https://grafana.kouni.io` | Auto-redirects to Google sign-in |
| Sign in with `@lcse.org` account | Account auto-created, role: **Viewer** |
| Sign in with non-`lcse.org` account | Rejected by Grafana |
| Promote user | Grafana UI → **Administration → Users → assign Editor/Admin** |
| Admin password login | `https://grafana.kouni.io/login?disableAutoLogin` |

### Change Grafana admin password

The chart default password is `prom-operator`. Set a strong password at install time via `--set grafana.adminPassword=` (see Step 3 above). Do **not** commit a plaintext password to this file.

### Import dashboards

Community dashboards (import by ID in Grafana → Dashboards → Import):

| ID   | Name                        | Purpose              |
|------|-----------------------------|----------------------|
| 1860 | Node Exporter Full          | Detailed node metrics|
| 6336 | Kubernetes Pods             | Pod-level metrics    |
| 7249 | Kubernetes Cluster Overview | Cluster overview     |

In-repo dashboard (`k8s/monitoring/dashboards/`):

```
Dashboards → New → Import → Upload JSON file
→ k8s/monitoring/dashboards/oci-oke-cluster-formosa.json
```

## Operations

### Upgrade values

```bash
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/values-kube-prometheus-stack.yaml
```

### Uninstall

```bash
helm uninstall kube-prometheus-stack --namespace monitoring
# PVCs are RETAINED (Prometheus and AlertManager use StatefulSet volumeClaimTemplates;
# Grafana PVC is protected by helm.sh/resource-policy: keep annotation).
# Delete manually only when you want to permanently remove all data:
# kubectl -n monitoring delete pvc --all
```

### Re-attach Grafana PVC after fresh install

If you uninstall and reinstall the chart, re-label the retained Grafana PVC so Helm
re-adopts it instead of creating a new one:

```bash
PVC=kube-prometheus-stack-grafana
kubectl -n monitoring annotate pvc "$PVC" \
  meta.helm.sh/release-name=kube-prometheus-stack \
  meta.helm.sh/release-namespace=monitoring --overwrite
kubectl -n monitoring label pvc "$PVC" \
  app.kubernetes.io/managed-by=Helm --overwrite
```

## Future Expansion

To add log aggregation and distributed tracing later:

1. Deploy **Loki** (logs) + **Alloy** (log shipper DaemonSet)
2. Deploy **Tempo** (traces, OTLP receiver)
3. Add `additionalScrapeConfigs` for Loki and Tempo in `values-kube-prometheus-stack.yaml`
4. Add Loki datasource to Grafana via `additionalDataSources`

These are intentionally omitted from the current minimal stack to reduce resource usage
and operational complexity.

