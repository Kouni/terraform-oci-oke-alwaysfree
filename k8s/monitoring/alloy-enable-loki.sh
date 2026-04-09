#!/usr/bin/env bash
# alloy-enable-loki.sh
#
# Patches the Alloy ConfigMap to add a loki.write "local" block and enable
# dual-write (Grafana Cloud + local Loki) for pod logs and Kubernetes events.
#
# Prerequisites:
#   - kubectl configured and pointing at the correct cluster
#   - Loki already deployed: helm upgrade --install loki grafana/loki -n monitoring ...
#
# Usage:
#   chmod +x k8s/monitoring/alloy-enable-loki.sh
#   ./k8s/monitoring/alloy-enable-loki.sh [namespace]
#
# Default namespace: monitoring
# The script is idempotent — safe to run multiple times.

set -euo pipefail

NAMESPACE="${1:-monitoring}"
CM_NAME="alloy"
DS_NAME="alloy"

echo "==> Namespace: ${NAMESPACE}"

# ── Fetch current config ──────────────────────────────────────────────────────
CURRENT=$(kubectl get configmap "${CM_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.config\.alloy}')

if echo "${CURRENT}" | grep -q 'loki.write "local"'; then
  echo "==> loki.write \"local\" already present — nothing to do."
  exit 0
fi

# ── Build patched config ──────────────────────────────────────────────────────
LOKI_ENDPOINT="http://loki.${NAMESPACE}.svc.cluster.local:3100/loki/api/v1/push"

PATCHED=$(printf '%s' "${CURRENT}" | python3 - "${LOKI_ENDPOINT}" <<'PYEOF'
import sys, re

loki_endpoint = sys.argv[1]
config = sys.stdin.read()

def find_block_end(s, start):
    """Return index just past the closing brace of the block starting at start."""
    depth = 0
    for i in range(start, len(s)):
        if s[i] == '{':
            depth += 1
        elif s[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1

# 1. Add loki.write "local" after the closing brace of loki.write "grafana_cloud"
m = re.search(r'loki\.write "grafana_cloud"\s*\{', config)
if m:
    block_end = find_block_end(config, m.start())
    local_block = (
        '\n\nloki.write "local" {\n'
        f'  endpoint {{\n'
        f'    url = "{loki_endpoint}"\n'
        f'  }}\n'
        f'}}'
    )
    config = config[:block_end] + local_block + config[block_end:]
else:
    print("ERROR: could not find loki.write \"grafana_cloud\" block", file=sys.stderr)
    sys.exit(1)

# 2. Update forward_to in loki.process "pod_logs"
config = re.sub(
    r'(loki\.process "pod_logs" \{.*?forward_to\s*=\s*\[)(loki\.write\.grafana_cloud\.receiver)(\])',
    r'\1\2, loki.write.local.receiver\3',
    config,
    flags=re.DOTALL,
)

# 3. Update forward_to in loki.source.kubernetes_events
config = re.sub(
    r'(loki\.source\.kubernetes_events "cluster" \{.*?forward_to\s*=\s*\[)(loki\.write\.grafana_cloud\.receiver)(\])',
    r'\1\2, loki.write.local.receiver\3',
    config,
    flags=re.DOTALL,
)

print(config, end='')
PYEOF
)

# ── Apply patch ───────────────────────────────────────────────────────────────
kubectl create configmap "${CM_NAME}" \
  --from-literal="config.alloy=${PATCHED}" \
  --namespace "${NAMESPACE}" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

echo "==> ConfigMap patched."

# ── Restart Alloy DaemonSet to pick up new config ────────────────────────────
kubectl rollout restart daemonset/"${DS_NAME}" -n "${NAMESPACE}"
kubectl rollout status daemonset/"${DS_NAME}" -n "${NAMESPACE}" --timeout=120s

echo "==> Done. Alloy is now dual-writing logs to Grafana Cloud and local Loki."
echo "    Verify: kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=alloy --tail=20"
