# Grafana Dashboards

Source-of-truth JSON exports for Grafana dashboards used by this cluster.

## Files

| File | Title | Datasources |
|------|-------|-------------|
| `cluster-overview.json` | OKE Formosa - Cluster Overview | Prometheus, Loki |

### `cluster-overview.json` rows

1. **(header)** - Nodes Ready, Running Pods, Restarts (24h), CPU, Memory, Disk
2. **Worker Node** - per-node health, CPU/memory, disk, network
3. **Services & Workloads** - deployments, statefulsets, daemonsets, pod phases, restarts
4. **Pod Resources** - CPU/memory by pod, network by pod
5. **Logs & Events** - error logs, warning events, log volume by namespace
6. **Cluster Critical Path** - apiserver 5xx / p99 / NFS provisioner health & restarts
7. **Node Saturation** - root fs / conntrack / file descriptors / disk I/O
8. **Observability Backplane** - Loki & Tempo ingestion + 5xx, observability pods up
9. **Top-N Pods** - top 10 by CPU and memory (working set)
10. **Cloudflare Tunnel** - cloudflared readiness, restarts, CPU, memory

Some panels in rows 6-10 depend on metrics emitted by specific Helm
releases (kube-state-metrics, node-exporter, Loki, Tempo). Empty panels
are an indication that the corresponding component is not deployed or
its `ServiceMonitor` is missing.

## Update workflow

1. Edit dashboard in Grafana UI (Cloudflare Tunnel or port-forward).
2. Dashboard - Settings - JSON Model - copy.
3. Paste into the matching file here, format with `jq . file.json | sponge file.json`.
4. Strip emoji per repo convention (only Enclosed Alphanumerics like
   `Alpha` / `Beta` / `Delta` are allowed).
5. Commit with `docs(dashboards): ...` message.

## Import

Import into Grafana via UI:

```
Dashboards -> New -> Import -> Upload JSON file
```

Or via API:

```bash
GRAFANA_URL=http://localhost:3000
TOKEN=...
curl -sS -X POST "$GRAFANA_URL/api/dashboards/db" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @cluster-overview.json
```

## Sidecar auto-provisioning (optional)

To have the kube-prometheus-stack Grafana sidecar pick these up automatically,
wrap each file in a ConfigMap with the `grafana_dashboard: "1"` label and apply
to the `monitoring` namespace. Not configured by default to keep dashboards
editable in-place via the UI without ConfigMap drift.
