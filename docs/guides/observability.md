# OKE Always Free — Observability Stack

> **Scope:** Prometheus (metrics) + Grafana (dashboards) + AlertManager (notifications).
> Deployed manually via Helm. Not managed by OpenTofu.

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
| Grafana            | 100m    | 512 Mi  | 500m      | 1 Gi      |
| AlertManager       | 50m     | 128 Mi  | 200m      | 256 Mi    |
| kube-state-metrics | 50m     | 128 Mi  | 200m      | 256 Mi    |
| node-exporter      | 50m     | 64 Mi   | 200m      | 128 Mi    |
| Prometheus Operator| 100m    | 256 Mi  | 300m      | 512 Mi    |
| **Total Request**  | ~650m   | ~1.6 Gi |           |           |

A1.Flex available (after OS + system pods): ~3300m CPU, ~22 Gi RAM.

## Deployment

### Prerequisites

```bash
kubectl cluster-info                # cluster reachable
kubectl get sc nfs                  # NFS StorageClass must exist
helm version                        # Helm 3.x
kubectl -n monitoring get secret grafana-admin   # created by `tofu apply`
```

The `grafana-admin` Secret holds the Grafana admin credentials. It is created by
`tofu apply` (`random_password.grafana_admin` in `main.tf`) and referenced by
`grafana.admin.existingSecret` in the Helm values. Never pass `adminPassword`
through `--set` or commit it to a values file.

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

Verify: open `https://grafana.kouni.io` — it redirects to Cloudflare Access (see [Sign-in](#sign-in-cloudflare-access-jwt)).

### Cloudflare Access (edge authentication)

Cloudflare Access is the only sign-in path. Unauthenticated requests are blocked at
the edge and never reach the Grafana pod, which also stops scanner traffic (probes
for `/.env` or `/terraform.tfstate` previously caused memory bursts large enough to
SIGKILL the container).

In the **Cloudflare Zero Trust Dashboard**:

1. **Settings → Authentication → Login methods**: add **Google**.
2. **Access → Applications → Add an application → Self-hosted and private → Public DNS**:

   | Field                          | Value                            |
   |--------------------------------|----------------------------------|
   | Public hostname                | `grafana.kouni.io` (no path)     |
   | Session duration               | `24 hours`                       |
   | Identity providers             | Google only                      |
   | Apply instant authentication   | On                               |

3. Attach a policy:

   | Field   | Value                            |
   |---------|----------------------------------|
   | Action  | `Allow` (not `Bypass` — Bypass does not issue the JWT Grafana needs) |
   | Include | **Emails ending in** `@lcse.org` |

4. **Networks → Tunnels → your tunnel → Public hostname `grafana.kouni.io` → Access**:
   enable **Protect with Access** for the same application, so cloudflared itself
   rejects requests without a valid Access token.

Verify from an unauthenticated session; the response should be a redirect to
`kouni.cloudflareaccess.com`, not Grafana:

```bash
curl -sI https://grafana.kouni.io/.env | grep -i '^location'
```

The redirect URL also exposes the application's AUD tag as the `kid` query parameter.
If the Access application is recreated, update `expect_claims` in the Helm values.

### Port-forward (local / fallback)

```bash
./scripts/port-forward-monitoring.sh
# Grafana:    http://localhost:3000
# Prometheus: http://localhost:9090
```

## Initial Setup

### Sign-in (Cloudflare Access JWT)

Users authenticate once, at Cloudflare Access (Google IdP). Access forwards every
request with a signed `Cf-Access-Jwt-Assertion` header, and Grafana's `auth.jwt`
signs the user in from it:

| Setting          | Value                                                               |
|------------------|---------------------------------------------------------------------|
| `jwk_set_url`    | `https://kouni.cloudflareaccess.com/cdn-cgi/access/certs`           |
| `expect_claims`  | `aud` = the Access application's AUD tag, `iss` = the team domain   |
| User identity    | `email` claim (auto sign-up)                                        |
| Role             | `role_attribute_path`, re-evaluated on every request                |

Built-in password login (`auth.disable_login`) and HTTP Basic auth
(`auth.basic.enabled: false`) are disabled, so the admin password cannot be used
through the public URL. Port-forward access has no Access JWT and therefore cannot
sign in either.

| Scenario | Behaviour |
|----------|-----------|
| Visit `https://grafana.kouni.io` | Cloudflare Access → Google sign-in (once) → Grafana |
| `@lcse.org` account | Account auto-created, role: **Viewer** |
| Account listed in `role_attribute_path` | Role: **Grafana Admin** |
| Any other account | Rejected by the Access policy |
| Promote user | Add the email to `role_attribute_path` in the Helm values (UI role changes are overwritten) |
| Password login (form, `POST /login`, Basic auth) | Disabled |
| Grafana **Sign out** | Redirects to `/cdn-cgi/access/logout` (`auth.signout_redirect_url`), revoking the Access session for **all** Access applications (n8n, Prometheus, …); Access has no per-app logout |

### Google OAuth (disabled fallback)

Grafana's own Google OAuth (`auth.google`) is disabled because it caused a second
Google consent prompt after Access. Its configuration and the `grafana-google-oauth`
Secret are kept so it can be re-enabled (`auth.google.enabled: true`,
`auto_login: true`) if Cloudflare Access is ever removed. Setup reference:

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
  --wait --timeout 10m
```

### Rotate Grafana admin password

The admin password is generated by OpenTofu and stored in the `grafana-admin` Secret. It is not usable through the public URL, but it still protects the local admin account. To rotate it:

```bash
tofu apply -replace=random_password.grafana_admin
```

`terraform_data.sync_grafana_admin_password` then runs `grafana cli admin reset-admin-password` inside the Grafana pod, because Grafana only reads the admin password from the environment when it first creates its database.

### Custom alert rules

`additionalPrometheusRulesMap` in `values-kube-prometheus-stack.yaml` adds rules that
the chart defaults do not cover:

| Alert                | Severity | Fires when                                                   |
|----------------------|----------|--------------------------------------------------------------|
| `ContainerSigKilled` | warning  | A container restarted in the last 15 min with exit code 137  |
| `ContainerRestarted` | info     | Any container restarted in the last hour                     |

Exit code 137 covers both cgroup OOM kills and liveness-probe kills. CRI-O on cgroup v2
may report `reason=Error` instead of `OOMKilled`, so the alert keys on the exit code.

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

### Upgrade chart major version

Helm does not upgrade CRDs. Before a major chart bump, check
[UPGRADE.md](https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/UPGRADE.md)
for breaking changes, then apply the CRDs matching the new chart's `appVersion`
(the prometheus-operator version):

```bash
helm repo update
OPERATOR_VERSION=$(helm show chart prometheus-community/kube-prometheus-stack | awk '/^appVersion:/ {print $2}')
for crd in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents \
           prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
  kubectl apply --server-side --force-conflicts -f \
    "https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/${OPERATOR_VERSION}/example/prometheus-operator-crd/monitoring.coreos.com_${crd}.yaml"
done

helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values k8s/monitoring/values-kube-prometheus-stack.yaml \
  --wait --timeout 10m
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

