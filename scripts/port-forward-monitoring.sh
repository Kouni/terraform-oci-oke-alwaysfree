#!/usr/bin/env bash
# ──────────────── port-forward-monitoring.sh ────────────────
# Start port-forward for monitoring components (Grafana / Prometheus).
# Usage: ./scripts/port-forward-monitoring.sh
# Stop:  Ctrl+C
set -euo pipefail

NAMESPACE="monitoring"
PIDS=()

cleanup() {
  echo ""
  echo "Stopping all port-forwards..."
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "Starting monitoring port-forwards..."
echo ""

kubectl -n "$NAMESPACE" port-forward svc/kube-prometheus-stack-grafana 3000:80 &
PIDS+=($!)

kubectl -n "$NAMESPACE" port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
PIDS+=($!)

cat <<'EOF'

Monitoring component access URLs
  Grafana:    http://localhost:3000
  Prometheus: http://localhost:9090

Press Ctrl+C to stop all port-forwards.
EOF

wait
