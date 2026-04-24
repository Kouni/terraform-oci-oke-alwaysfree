# Grafana Dashboards

Source-of-truth JSON exports for Grafana dashboards used by this cluster.

## Files

| File | Title | Datasources |
|------|-------|-------------|
| `cluster-overview.json` | OKE Formosa - Cluster Overview | Prometheus, Loki |

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
