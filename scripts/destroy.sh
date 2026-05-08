#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# destroy.sh — Safe Terraform destroy wrapper
#
# Usage:
#   bash scripts/destroy.sh               # interactive confirmation
#   bash scripts/destroy.sh -auto-approve # non-interactive
#
# Why this script exists:
#   terraform destroy can fail or leave orphaned OCI resources for two reasons:
#
#   1. The OCI Block Volume backing the NFS server PVC is not deleted unless
#      the Kubernetes CSI driver explicitly calls the OCI API. If we remove
#      helm/kubernetes resources from state and then destroy the node pool,
#      the CSI driver is killed with the nodes before it can clean up the
#      block volume. This script deletes PVCs via kubectl first so the CSI
#      driver can complete its cleanup while nodes are still running.
#
#   2. The Helm/Kubernetes provider times out with "context deadline exceeded"
#      when the OKE API server becomes unreachable after nodes are terminated.
#
#   OCI destroys all remaining in-cluster resources (namespaces, Deployments,
#   Helm releases) automatically when the OKE cluster is deleted. Terraform
#   does not need to manage their deletion — only PVCs need explicit cleanup
#   to trigger CSI block volume deletion.
#
# Requires: terraform, kubectl (for PVC cleanup)
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# ── Step 1: Delete PVCs so CSI driver cleans up OCI Block Volumes ─────────────
# This MUST happen before state removal and cluster teardown. The oci-bv-xfs
# StorageClass uses reclaimPolicy=Delete — the CSI driver calls the OCI API
# to delete the backing block volume when the PVC is deleted. If the nodes
# are gone first, that API call never happens and the volume is orphaned.

echo "Deleting PVCs to let CSI driver clean up OCI Block Volumes..."
if kubectl get nodes &>/dev/null 2>&1; then
  # Application PVCs first (backed by NFS subdirectory, not OCI directly)
  kubectl delete pvc n8n-data -n n8n --ignore-not-found --wait=true --timeout=60s || true

  # NFS server backing PVC — this is backed directly by an OCI Block Volume.
  # Deleting it triggers the CSI driver to delete the block volume via OCI API.
  kubectl delete pvc --all -n nfs-storage --ignore-not-found --wait=true --timeout=120s || true

  echo "PVC cleanup complete."
else
  echo "Cluster not reachable — skipping PVC cleanup (block volumes may need manual deletion)."
fi

echo ""

# ── Step 2: Remove in-cluster resources from state ────────────────────────────

echo "Removing in-cluster resources from Terraform state..."
echo "(OKE cluster deletion removes all remaining Kubernetes resources automatically)"
echo ""

removed=0
while IFS= read -r resource; do
  [[ -z "$resource" ]] && continue
  echo "  Removing: $resource"
  terraform state rm "$resource" && ((removed += 1)) || true
done < <(terraform state list 2>/dev/null \
  | grep -E '^(kubernetes_|helm_release\.)' || true)

if [[ $removed -eq 0 ]]; then
  echo "  Nothing to remove — state already clean."
fi

echo ""

# ── Step 3: Destroy OCI infrastructure ────────────────────────────────────────

terraform destroy "$@"
