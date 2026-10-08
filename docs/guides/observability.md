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
│ NFS PVC 35Gi │     │ NFS PVC 1Gi  │
│retention 180d│     │ retention 5d │
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
| Prometheus   | 35 Gi     | `retentionSize=31GB`, `retention=180d`, WAL compression on   |
| Grafana      | 2 Gi      | `helm.sh/resource-policy: keep` annotation                    |
| AlertManager | 1 Gi      | `retention=120h` (5 days)                                     |
| **Total**    | **38 Gi** | 28 % of 136 Gi NFS                                            |

Sizing basis (measured 2026-10): ~40k active series (the `apiserver` job alone
contributes ~27k samples per scrape), ~1,400 samples/s × ~1.15 B/sample ≈
**~140 MB/day** → ~23.5 GiB at 180 days. Adding 20 % for series growth and
~1 GiB for the WAL gives ~29 GiB, rounded up to `retentionSize=31GB`.
Prometheus size units are base-2, so `31GB` means 31 GiB. That leaves ~4 GiB
under the 35 Gi quota for compaction output. The largest block spans ~10 % of
retention, about 2.5 GB.

Whichever of `retention` and `retentionSize` is reached first wins. Check the
effective retention with
`time() - prometheus_tsdb_lowest_timestamp_seconds` (in seconds).

## Resource Budget

| Component          | CPU Req | Mem Req | CPU Limit | Mem Limit |
|--------------------|---------|---------|-----------|-----------|
| Prometheus         | 300m    | 512 Mi  | 1000m     | 2 Gi      |
| Grafana            | 100m    | 512 Mi  | 500m      | 1.5 Gi    |
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

### Resizing Prometheus Storage

Resize the existing Prometheus PVC in place. Do not create a new SC, PV, or PVC.
The example below grows the volume from 5 Gi to 35 Gi and extends retention
from 90d to 180d.

#### Why editing the PVC is not enough

With a CSI-backed StorageClass, raising `spec.resources.requests.storage` on a
PVC triggers the external resizer. The `nfs` StorageClass works differently:

- **The real limit is an XFS project quota.** `nfs-provisioner` (v4.0.8)
  creates one directory per PVC under `/export` on the NFS server and caps it
  with an XFS project quota. The size on the PV and PVC is only metadata and does
  not limit writes.
- **There is no resizer.** The StorageClass reports
  `allowVolumeExpansion: true`, but nothing acts on a resize. Patching the PVC
  only emits an `ExternalExpanding` event and then stays pending.
- **The provisioner re-applies quotas on startup.** It reads `/export/projects`
  and resets every quota to the size stored there. If you change only the live
  quota, the old size comes back on the next restart.
- **A StatefulSet's `volumeClaimTemplates` are immutable.** Prometheus runs in
  an operator-managed StatefulSet, so the template change must follow the
  operator's documented resize flow.

Five layers must end up consistent: **XFS quota → `/export/projects` → PV → PVC
→ Prometheus CR / StatefulSet / Helm values**.

#### Step 0 — Pre-checks and backups

```bash
kubectl config current-context

PVC=prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
PV=$(kubectl -n monitoring get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
PROJECT_ID=$(kubectl get pv "$PV" -o jsonpath='{.metadata.annotations.Project_Id}')
echo "$PV $PROJECT_ID"

kubectl -n nfs-storage exec nfs-server-provisioner-0 -- xfs_quota -x -c 'report -p -h' /export

mkdir -p temporary/prom-resize
kubectl -n nfs-storage exec nfs-server-provisioner-0 -- cat /export/projects > temporary/prom-resize/projects.bak
kubectl get pv "$PV" -o yaml > temporary/prom-resize/pv.yaml
kubectl -n monitoring get pvc "$PVC" -o yaml > temporary/prom-resize/pvc.yaml
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o yaml > temporary/prom-resize/cr.yaml
kubectl get sc,pv -o name > temporary/prom-resize/before.txt
kubectl get pvc -A --no-headers | awk '{print $1"/"$2}' >> temporary/prom-resize/before.txt

# The live release must match the repo, or the upgrade will overwrite live-only changes
diff <(helm -n monitoring get values kube-prometheus-stack -o json | jq -S .) \
     <(yq -o json k8s/monitoring/values-kube-prometheus-stack.yaml | jq -S .)

# PVCs must survive the StatefulSet deletion in Step 7 (expect Retain/Retain)
kubectl -n monitoring get sts prometheus-kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.persistentVolumeClaimRetentionPolicy}{"\n"}'
```

Every later step needs the PV name and project ID. The backups let you revert
each layer separately.

#### Step 1 — Size the volume

Measure the current ingestion before you pick a number:

```promql
rate(prometheus_tsdb_head_samples_appended_total[1h])   # samples/s
prometheus_tsdb_storage_blocks_bytes                     # current block size
time() - prometheus_tsdb_lowest_timestamp_seconds        # effective retention (s)
```

- Daily growth = block size ÷ effective retention in days (~140 MB/day as of 2026-10).
- `retentionSize` = days × daily growth × 1.2 (series growth) + ~1 GiB (WAL).
- PVC quota = `retentionSize` + ~10 %. Compaction writes the new block before it
  deletes the source blocks, so it needs temporary headroom.
- **Prometheus size units are base-2.** `31GB` means 31 GiB (33.3e9 bytes).

For 180 days: `retentionSize: 31GB`, quota 35 Gi = 35 × 1024³ = `37580963840` bytes.

#### Step 2 — Update the values file

Set `retention`, `retentionSize`, and `storageSpec.volumeClaimTemplate...storage`
in `k8s/monitoring/values-kube-prometheus-stack.yaml`. The `storage` value does
not expand the existing PVC. Keep it in sync anyway: the operator uses it when
it recreates the StatefulSet, and a fresh install uses it too.

#### Step 3 — Raise the XFS quota

```bash
NEW_SIZE=35Gi
NEW_BYTES=37580963840

# 3a. Persist the new size so it survives provisioner restarts
kubectl -n nfs-storage exec nfs-server-provisioner-0 -- sed -i \
  "s#^${PROJECT_ID}:/export/${PV}:[0-9]*\$#${PROJECT_ID}:/export/${PV}:${NEW_BYTES}#" /export/projects
kubectl -n nfs-storage exec nfs-server-provisioner-0 -- cat /export/projects

# 3b. Apply the live quota
kubectl -n nfs-storage exec nfs-server-provisioner-0 -- \
  xfs_quota -x -c "limit -p bhard=${NEW_BYTES} ${PROJECT_ID}" /export

# 3c. Verify: the project's Hard column shows 35G
kubectl -n nfs-storage exec nfs-server-provisioner-0 -- xfs_quota -x -c 'report -p -h' /export
```

You need both 3a and 3b: 3b applies the new limit now, and 3a keeps it after a
restart. Run 3a first. If the `sed` is wrong, the live quota is still unchanged.
Check that only this project's line changed.

#### Step 4 — Update the PV

```bash
kubectl patch pv "$PV" --type merge -p "$(jq -n \
  --arg b $'\n'"${PROJECT_ID}:/export/${PV}:${NEW_BYTES}"$'\n' --arg s "$NEW_SIZE" \
  '{metadata:{annotations:{Project_block:$b}},spec:{capacity:{storage:$s}}}')"

kubectl get pv "$PV" -o jsonpath='{.metadata.annotations.Project_block}{"\n"}{.spec.capacity}{"\n"}'
```

- **`Project_block` must match `/export/projects` exactly.** When the PV is
  deleted, the provisioner removes this exact string from the projects file. If
  the annotation still has the old size, the match fails and a stale line stays
  in the file.
- `spec.capacity` only changes what `kubectl get pv` shows.

#### Step 5 — Pause the operator

```bash
kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus \
  --type merge -p '{"spec":{"paused":true}}'
```

Step 7 deletes the StatefulSet. A running operator would recreate it right away
from the old CR (5 Gi). This follows the prometheus-operator "Resizing volumes"
procedure.

#### Step 6 — Align the PVC spec and status

```bash
# 6a. Spec (allowed because the StorageClass has allowVolumeExpansion: true; grow only)
kubectl -n monitoring patch pvc "$PVC" --type merge \
  -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$NEW_SIZE\"}}}}"
kubectl -n monitoring get events --field-selector involvedObject.name="$PVC"   # ExternalExpanding is expected

# 6b. Status (kubectl >= 1.24); the CAPACITY column reads status.capacity
kubectl -n monitoring patch pvc "$PVC" --subresource=status --type merge \
  -p "{\"status\":{\"capacity\":{\"storage\":\"$NEW_SIZE\"}}}"

# 6c. Nothing left pending
kubectl -n monitoring get pvc "$PVC" -o json | jq '{ann:.metadata.annotations, spec:.spec.resources, status:.status}'
```

Normally the resizer writes `status.capacity` when it finishes. With no
resizer, set it by hand, or `kubectl get pvc` keeps showing the old size. In
6c, check that `status.conditions` has no `Resizing` or
`FileSystemResizePending` entry and that no
`volume.kubernetes.io/storage-resizer` annotation was added. Remove any you
find.

#### Step 7 — Orphan-delete the StatefulSet

```bash
kubectl -n monitoring delete sts prometheus-kube-prometheus-stack-prometheus --cascade=orphan
kubectl -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0   # still Running
```

The StatefulSet must be recreated before the new `volumeClaimTemplates` can
apply. `--cascade=orphan` leaves the pod and PVC in place, so Prometheus keeps
running.

#### Step 8 — Helm upgrade

```bash
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version "$(helm -n monitoring list -o json | jq -r '.[0].chart | sub("kube-prometheus-stack-"; "")')" \
  --values k8s/monitoring/values-kube-prometheus-stack.yaml \
  --force-conflicts \
  --wait --timeout 10m
```

- **Pin `--version` to the deployed chart.** Without it, the upgrade also bumps
  the chart and may pull in CRD or default-value changes.
- **Helm 4 requires `--force-conflicts`.** Helm 4 uses server-side apply.
  Step 5 set `spec.paused` with `kubectl patch`, and the chart also sets it
  (`false`). Without the flag, the upgrade fails with a field-manager conflict
  on `.spec.paused` after it has already applied other objects, such as
  Grafana. With the flag, Helm takes ownership of the field and sets it to
  `false`.
- This single apply writes the new retention, storage, and resources and also
  unpauses the operator. The operator finds no StatefulSet, recreates it from
  the 35 Gi template, and adopts the existing pod. The pod restarts once because
  its retention args changed, which causes a ~1 minute scrape gap. WAL replay
  keeps existing data.
- With Helm 3 (no server-side apply), drop `--force-conflicts` and unpause
  manually after the upgrade:
  `kubectl -n monitoring patch prometheus kube-prometheus-stack-prometheus --type merge -p '{"spec":{"paused":false}}'`

#### Step 9 — Verify

```bash
# CR unpaused and updated
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o json | \
  jq -c '.spec | {paused, retention, retentionSize, storage:.storage.volumeClaimTemplate.spec.resources}'

# StatefulSet recreated; pod mounts the SAME PVC
kubectl -n monitoring get sts,pod -l app.kubernetes.io/name=prometheus
kubectl -n monitoring get pod prometheus-kube-prometheus-stack-prometheus-0 \
  -o jsonpath='{.spec.volumes[?(@.persistentVolumeClaim)].persistentVolumeClaim.claimName}{"\n"}'

# No SC / PV / PVC added or removed
diff temporary/prom-resize/before.txt \
     <(kubectl get sc,pv -o name; kubectl get pvc -A --no-headers | awk '{print $1"/"$2}')

# Prometheus applied the new limits and kept old data
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090 &
curl -s localhost:19090/api/v1/status/runtimeinfo | jq .data.storageRetention   # "180d or 31GiB"
curl -s -G localhost:19090/api/v1/query \
  --data-urlencode 'query=(time()-prometheus_tsdb_lowest_timestamp_seconds)/86400' | jq '.data.result[0].value[1]'
curl -s localhost:19090/api/v1/targets | jq '[.data.activeTargets[] | select(.health!="up")]'   # []

# Quota and Helm values consistent
kubectl -n nfs-storage exec nfs-server-provisioner-0 -- xfs_quota -x -c 'report -p -h' /export
diff <(helm -n monitoring get values kube-prometheus-stack -o json | jq -S .) \
     <(yq -o json k8s/monitoring/values-kube-prometheus-stack.yaml | jq -S .)

rm -rf temporary/prom-resize
```

| Check                     | Expected                              | Why it matters                                    |
|---------------------------|---------------------------------------|---------------------------------------------------|
| CR                        | `paused: false`; new retention/storage | A paused operator ignores all later changes       |
| Pod PVC name              | Unchanged                             | Confirms no new, empty PVC was created            |
| SC / PV / PVC list        | Identical to Step 0                   | Confirms no added or removed storage resources    |
| Oldest data (days)        | Same as before the resize             | Confirms the resize did not delete data           |
| `storageRetention`        | `180d or 31GiB`                       | Effective setting inside Prometheus               |
| Unhealthy targets         | Empty                                 | Confirms scraping resumed                         |

The PVC `CAPACITY` column and kube-state-metrics'
`kube_persistentvolumeclaim_resource_requests_storage_bytes` show 35 Gi.
`kubelet_volume_stats_capacity_bytes` and `df` inside the pod show the whole
NFS backing volume (136 Gi) for every NFS PVC. That is expected.

#### Rollback

| Failed at | Action                                                                                     |
|-----------|--------------------------------------------------------------------------------------------|
| Step 3    | Restore `/export/projects` from `projects.bak`, then `xfs_quota limit` back to the old bytes |
| Step 4    | `kubectl patch` the annotation and capacity back from `pv.yaml`                            |
| Step 6    | A PVC cannot shrink. The fields are display-only, so keep them or reset `status.capacity` via `--subresource=status` |
| Step 7–8  | If the StatefulSet is not recreated, check that `spec.paused` is `false`, then read `kubectl -n monitoring logs deploy/kube-prometheus-stack-operator` |

#### Pitfalls

1. Changing only `storage` in the values file leaves the real limit at the old size.
2. Changing only the live quota reverts on the next provisioner restart, and
   Prometheus fails once the volume fills.
3. A stale `Project_block` leaves an orphaned line in `/export/projects` after
   the PV is deleted.
4. Deleting the StatefulSet without pausing lets the operator recreate it from the old spec.
5. Helm 4 without `--force-conflicts` fails partway through the upgrade.
6. Treating `GB` as decimal undersizes the buffer: Prometheus uses GiB.
7. Setting `retentionSize` equal to the PVC size leaves no compaction headroom,
   so the volume can fill and crash Prometheus.

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

