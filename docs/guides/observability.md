# OKE Always Free — Observability Stack

> Minimal three-component stack — **Prometheus** for metrics, **Loki** for logs,
> **Alloy** for log shipping. NFS-backed storage. No Tempo, no Pyroscope, no
> Thanos. ($0/year)

## Architecture

```
                ┌──────────────────────────────────────────┐
                │              Grafana (UI)                │
                │   (Cloudflare Tunnel or port-forward)    │
                └──────────────┬───────────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              ▼                                 ▼
    ┌──────────────────┐              ┌────────────────────┐
    │    Prometheus    │              │       Loki         │
    │  (metrics TSDB,  │              │  (log storage,     │
    │   self-scrape)   │              │   filesystem)      │
    └─────────▲────────┘              └─────────▲──────────┘
              │ scrape                          │ push
              │                                 │
    ┌─────────┴────────┐              ┌─────────┴──────────┐
    │ Pod /metrics +   │              │  Grafana Alloy     │
    │ kube-state-      │              │  (DaemonSet,       │
    │ metrics +        │              │  Pod logs only)    │
    │ node-exporter    │              │                    │
    └──────────────────┘              └────────────────────┘
              │
              ▼
       AlertManager (notifications)

      ───── All persistent data on NFS (XFS quotas enforce per-PVC limits) ─────
```

| Pillar      | Component             | Notes                                           |
|-------------|-----------------------|-------------------------------------------------|
| Metrics     | Prometheus            | Self-scrape; PromQL                             |
| Logs        | Loki + Alloy          | Alloy DaemonSet tails Pod stdout/stderr → Loki  |
| Alerting    | AlertManager          | Bundled with kube-prometheus-stack              |
| Dashboards  | Grafana               | Datasources auto-provisioned                    |

Tracing (Tempo) and continuous profiling (Pyroscope) are intentionally not
deployed — there are no instrumented workloads in this cluster. Add them only
when an actual app starts emitting traces / profiles.

## Storage Budget

All PVCs use the in-cluster `nfs` StorageClass. XFS project quotas enforce
per-PVC hard limits (configured via `--enable-xfs-quota` on the NFS provisioner).

| Component    | PVC Size | Retention                 |
|--------------|----------|---------------------------|
| Prometheus   | 15Gi     | `retention=30d` / `retentionSize=14GB` |
| Loki         | 30Gi     | `retention_period=8760h` (1 year)      |
| Grafana      | 2Gi      | Permanent (helm `keep` annotation)     |
| AlertManager | 1Gi      | `retention=120h`                       |
| **Total**    | **48Gi** | Out of 136Gi NFS = ~35%                |

## Resource Budget (Requests)

| Resource | Total Request | Available (single A1.Flex node) | Usage |
|----------|---------------|----------------------------------|-------|
| CPU      | ~750m         | 3290m                           | ~23%  |
| Memory   | ~2.6Gi        | 20.8Gi                          | ~13%  |

## Deployment

Manual Helm releases — kept out of Terraform so the observability stack can be
re-run / re-tuned without touching infrastructure.

### Prerequisites

```bash
kubectl cluster-info
helm version
kubectl get sc nfs                # NFS StorageClass must exist
kubectl top node
```

### Step 1 — Namespace

```bash
kubectl apply -f k8s/monitoring/namespace.yaml
```

### Step 2 — Helm repos

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Step 3 — kube-prometheus-stack

Includes Prometheus, Grafana, AlertManager, Prometheus Operator, node-exporter,
kube-state-metrics.

```bash
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f k8s/monitoring/values-kube-prometheus-stack.yaml \
  --wait --timeout 10m
```

Verify:

```bash
kubectl -n monitoring get pods,pvc
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000   default credentials: admin / prom-operator
```

### Step 4 — Loki

Single-binary mode, filesystem backend on NFS.

```bash
helm upgrade --install loki \
  grafana-community/loki \
  -n monitoring \
  -f k8s/monitoring/values-loki.yaml \
  --wait --timeout 5m
```

Verify:

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki
kubectl -n monitoring port-forward svc/loki 3100:3100
curl http://localhost:3100/ready
```

### Step 5 — Alloy (logs-only)

DaemonSet that tails Pod stdout/stderr and pushes to Loki. The chart's default
RBAC is missing `nodes/proxy`, so the values file adds it explicitly.

```bash
helm upgrade --install alloy \
  grafana/alloy \
  -n monitoring \
  -f k8s/monitoring/values-alloy.yaml \
  --wait --timeout 5m
```

Verify:

```bash
kubectl -n monitoring get ds
kubectl -n monitoring logs -l app.kubernetes.io/name=alloy --tail=30
# In Grafana → Explore → Loki → confirm logs are flowing
```

### Step 6 — Recommended Grafana dashboards

| ID   | Name                          | Purpose                  |
|------|-------------------------------|--------------------------|
| 7249 | Kubernetes Cluster Overview   | Cluster overview         |
| 1860 | Node Exporter Full            | Detailed node metrics    |
| 6336 | Kubernetes Pods               | Pod-level metrics        |

## External Access

### Port-forward (development / debugging)

```bash
./scripts/port-forward-monitoring.sh
# Grafana    http://localhost:3000
# Prometheus http://localhost:9090
# Loki       http://localhost:3100
```

### Cloudflare Tunnel (production)

Add a Grafana hostname to the existing Cloudflare Tunnel configuration:

```yaml
ingress:
  - hostname: grafana.example.com
    service: http://kube-prometheus-stack-grafana.monitoring.svc:80
```

## Operations

### Upgrade values

```bash
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f k8s/monitoring/values-kube-prometheus-stack.yaml
```

### Full removal (reverse order)

```bash
helm uninstall alloy             -n monitoring
helm uninstall loki              -n monitoring
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring   # WARNING: deletes all PVCs and data
```

### PVC lifecycle

| Component    | Deployment Type                 | PVC after `helm uninstall` |
|--------------|---------------------------------|----------------------------|
| Prometheus   | StatefulSet (volumeClaimTemplate) | Retained (managed by K8s) |
| AlertManager | StatefulSet (volumeClaimTemplate) | Retained (managed by K8s) |
| Loki         | StatefulSet (singleBinary)      | Retained (managed by K8s) |
| Grafana      | Deployment + PVC                | Retained via `helm.sh/resource-policy: keep` |

To re-attach Grafana's PVC after a fresh install, re-label it for Helm:

```bash
PVC=kube-prometheus-stack-grafana
kubectl -n monitoring annotate pvc "$PVC" \
  meta.helm.sh/release-name=kube-prometheus-stack \
  meta.helm.sh/release-namespace=monitoring --overwrite
kubectl -n monitoring label pvc "$PVC" \
  app.kubernetes.io/managed-by=Helm --overwrite
```

### Verify XFS quotas are active

```bash
NFS_POD=$(kubectl -n nfs-storage get pod -l app=nfs-server-provisioner -o jsonpath='{.items[0].metadata.name}')
kubectl -n nfs-storage exec "$NFS_POD" -- xfs_quota -x -c 'report -h' /export
# Expect one entry per PVC with hard limit == requests.storage
```

## Troubleshooting

| Symptom                               | First check                                                                 |
|---------------------------------------|-----------------------------------------------------------------------------|
| Pod `ImagePullBackOff`                | OKE CRI-O requires fully qualified image paths (`docker.io/...`)            |
| PVC stuck `Pending`                   | `kubectl -n monitoring describe pvc <name>`; confirm NFS provisioner ready  |
| Grafana shows no Loki logs            | `kubectl -n monitoring logs -l app.kubernetes.io/name=alloy`                |
| Prometheus `OOMKilled`                | Reduce `retentionSize` or raise memory limit in values file                 |
| Helm install times out                | Increase `--timeout`; or drop `--wait` and observe progress manually         |

## Future Upgrade Path (deferred)

If retention or durability need to grow beyond local NFS:

1. Add Thanos sidecar to Prometheus + deploy Compactor / Store Gateway / Query.
2. Switch Loki to `storage.type: s3`.
3. Provide an object storage backend (Cloudflare R2 or OCI Object Storage S3-compat).
4. Re-introduce the corresponding example secret manifests at that time — they
   were intentionally removed because the current stack does not consume them.
